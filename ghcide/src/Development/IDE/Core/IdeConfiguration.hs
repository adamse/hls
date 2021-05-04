{-# LANGUAGE DuplicateRecordFields #-}
module Development.IDE.Core.IdeConfiguration
  ( IdeConfiguration(..)
  , registerIdeConfiguration
  , getIdeConfiguration
  , parseConfiguration
  , parseWorkspaceFolder
  , isWorkspaceFile
  , modifyWorkspaceFolders
  , modifyClientSettings
  , getClientSettings
  , makeRelativeToWorkspace)
where

import           Control.Concurrent.Strict
import           Control.Monad
import           Control.Monad.IO.Class
import           Data.Aeson.Types               (Value)
import           Data.Foldable                  (toList)
import           Data.HashSet                   (HashSet, singleton)
import           Data.Hashable                  (Hashed, hashed, unhashed)
import           Data.Maybe                     (catMaybes)
import           Data.Monoid                    (First (..))
import           Data.Text                      (Text, isPrefixOf)
import           Development.IDE.Core.Shake
import           Development.IDE.Graph
import           Development.IDE.Types.Location
import           Language.LSP.Types
import           System.FilePath                (isRelative, makeRelative)

-- | Lsp client relevant configuration details
data IdeConfiguration = IdeConfiguration
  { workspaceFolders :: HashSet NormalizedUri
  , clientSettings   :: Hashed (Maybe Value)
  }
  deriving (Show)

newtype IdeConfigurationVar = IdeConfigurationVar {unIdeConfigurationRef :: Var IdeConfiguration}

instance IsIdeGlobal IdeConfigurationVar

registerIdeConfiguration :: ShakeExtras -> IdeConfiguration -> IO ()
registerIdeConfiguration extras =
  addIdeGlobalExtras extras . IdeConfigurationVar <=< newVar

getIdeConfiguration :: Action IdeConfiguration
getIdeConfiguration =
  getIdeGlobalAction >>= liftIO . readVar . unIdeConfigurationRef

parseConfiguration :: InitializeParams -> IdeConfiguration
parseConfiguration InitializeParams {..} =
  IdeConfiguration {..}
 where
  workspaceFolders =
    foldMap (singleton . toNormalizedUri) _rootUri
      <> (foldMap . foldMap)
           (singleton . parseWorkspaceFolder)
           _workspaceFolders
  clientSettings = hashed _initializationOptions

parseWorkspaceFolder :: WorkspaceFolder -> NormalizedUri
parseWorkspaceFolder =
  toNormalizedUri . Uri . (_uri :: WorkspaceFolder -> Text)

modifyWorkspaceFolders
  :: IdeState -> (HashSet NormalizedUri -> HashSet NormalizedUri) -> IO ()
modifyWorkspaceFolders ide f = modifyIdeConfiguration ide f'
  where f' (IdeConfiguration ws initOpts) = IdeConfiguration (f ws) initOpts

modifyClientSettings
  :: IdeState -> (Maybe Value -> Maybe Value) -> IO ()
modifyClientSettings ide f = modifyIdeConfiguration ide f'
  where f' (IdeConfiguration ws clientSettings) =
            IdeConfiguration ws (hashed . f . unhashed $ clientSettings)

modifyIdeConfiguration
  :: IdeState -> (IdeConfiguration -> IdeConfiguration) -> IO ()
modifyIdeConfiguration ide f = do
  IdeConfigurationVar var <- getIdeGlobalState ide
  void $ modifyVar' var f

isWorkspaceFile :: NormalizedFilePath -> Action Bool
isWorkspaceFile file =
  if isRelative (fromNormalizedFilePath file)
    then return True
    else do
      IdeConfiguration {..} <- getIdeConfiguration
      let toText = getUri . fromNormalizedUri
      return $
        any
          (\root -> toText root `isPrefixOf` toText (filePathToUri' file))
          workspaceFolders

getClientSettings :: Action (Maybe Value)
getClientSettings = unhashed . clientSettings <$> getIdeConfiguration

makeRelativeToWorkspace :: NormalizedFilePath -> Action (Maybe FilePath)
makeRelativeToWorkspace nfp = do
    roots <- map (uriToFilePath . fromNormalizedUri) . toList . workspaceFolders <$> getIdeConfiguration
    return $ getFirst . foldMap (First . tryMakeRelative) $ catMaybes roots
  where
      p = fromNormalizedFilePath nfp
      tryMakeRelative root =
          let p' = makeRelative root p
          in guard (isRelative p') >> return p'
