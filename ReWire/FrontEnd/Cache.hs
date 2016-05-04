{-# LANGUAGE LambdaCase, FlexibleInstances, TupleSections, NamedFieldPuns, ViewPatterns #-}
module ReWire.FrontEnd.Cache
      ( runCache
      , getProgram
      , LoadPath
      , printInfo
      ) where

import ReWire.Annotation
import ReWire.Error
import ReWire.FrontEnd.Annotate
import ReWire.FrontEnd.Desugar
import ReWire.FrontEnd.KindCheck
import ReWire.FrontEnd.PrimBasis
import ReWire.FrontEnd.Rename
import ReWire.FrontEnd.Syntax
import ReWire.FrontEnd.ToCore
import ReWire.FrontEnd.ToMantle
import ReWire.FrontEnd.Transform
import ReWire.FrontEnd.TypeCheck
import ReWire.Pretty

import Control.Monad ((>=>), liftM, msum)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.Reader (runReaderT, ReaderT, MonadReader (..))
import Control.Monad.State.Strict (runStateT, StateT, MonadState (..), modify)
import Data.Monoid ((<>))
import Language.Haskell.Exts.Annotated (parseFileWithMode, ParseResult (..), defaultParseMode, ParseMode (..))
import Language.Haskell.Exts.Annotated.Simplify (sModuleName)
import System.Directory (getCurrentDirectory, setCurrentDirectory, doesFileExist, doesDirectoryExist)

import qualified Data.Map.Strict              as Map
import qualified Language.Haskell.Exts.Syntax as S
import qualified ReWire.Core.Syntax           as Core

import Language.Haskell.Exts.Annotated.Syntax hiding (Annotation, Namespace, Name, Kind)

import Unbound.Generics.LocallyNameless (runFreshMT, FreshMT (..), Alpha)

type Cache = ReaderT LoadPath (StateT ModCache (FreshMT (SyntaxErrorT IO)))
type LoadPath = [FilePath]
type ModCache = Map.Map FilePath (RWMModule, Exports)

runCache :: Cache a -> LoadPath -> IO (Either AstError a)
runCache m lp = runSyntaxError $ fst <$> runFreshMT (runStateT (runReaderT m lp) mempty)

mkRenamer :: Annotation a => Module a -> Cache Renamer
mkRenamer m = mconcat <$> mapM mkRenamer' (getImps m)
      where mkRenamer' :: Annotation a => ImportDecl a -> Cache Renamer
            mkRenamer' (ImportDecl _ (sModuleName -> m) quald _ _ _ (fmap sModuleName -> as) specs) = do
                  (_, exps) <- getModule $ toFilePath m
                  fromImps m quald exps as specs

getImps :: Annotation a => Module a -> [ImportDecl a]
getImps = \ case
      Module l _ _ imps _            -> addPrelude l imps
      XmlPage {}                     -> []
      XmlHybrid l _ _ imps _ _ _ _ _ -> addPrelude l imps
      where addPrelude :: Annotation a => a -> [ImportDecl a] -> [ImportDecl a]
            addPrelude l imps =
                  if any isPrelude imps
                        then imps
                        else ImportDecl l (ModuleName l "Prelude") False False False Nothing Nothing Nothing : imps
            isPrelude :: Annotation a => ImportDecl a -> Bool
            isPrelude ImportDecl { importModule = ModuleName _ n } = n == "Prelude"

-- Pass 1    Parse.
-- Pass 2-4  Fixity fixing (uniquify + fix + deuniquify, because bug in applyFixities).
-- Pass 5    Annotate.
-- Pass 6-14 Desugar.
-- Pass 15   Translate to mantle + rename globals.
-- Pass 16   Translate to core

getModule :: FilePath -> Cache (RWMModule, Exports)
getModule fp = Map.lookup fp <$> get >>= \ case
      Just p  -> return p
      Nothing -> do
            modify $ Map.insert fp mempty

            lp         <- ask
            mmods      <- mapM tryParseInDir lp
            -- FIXME: The directory crawling could be more robust here. (Should
            -- use exception handling.)
            m          <- maybe (failAt (filePath fp) "File not found in loadpath") return $ msum mmods

            rn         <- mkRenamer m
            imps       <- loadImports m

            -- Phase 1 (haskell-src-exts) transformations.
            (m', exps) <- fixFixity rn
                      >=> annotate
                      >=> desugar
                      >=> toMantle rn $ m

            modify $ Map.insert fp (m' <> imps, exps)
            return (m' <> imps, exps)

      where tryParseInDir :: FilePath -> Cache (Maybe (Module SrcSpanInfo))
            tryParseInDir dp = do
                  dExists <- liftIO $ doesDirectoryExist dp
                  if not dExists then return Nothing else do
                        oldCwd <- liftIO getCurrentDirectory
                        liftIO $ setCurrentDirectory dp
                        exists <- liftIO $ doesFileExist fp
                        result <- if not exists then return Nothing else do
                              pr <- liftIO parse
                              Just <$> pr2Cache pr
                        liftIO $ setCurrentDirectory oldCwd
                        return result

            parse :: IO (ParseResult (Module SrcSpanInfo))
            parse = parseFileWithMode defaultParseMode { parseFilename = fp, fixities = Nothing } fp

            pr2Cache :: ParseResult a -> Cache a
            pr2Cache = \ case
                  ParseOk p                         -> return p
                  ParseFailed (S.SrcLoc "" r c) msg -> failAt (S.SrcLoc fp r c) msg
                  ParseFailed l msg                 -> failAt l msg

            loadImports :: Annotation a => Module a -> Cache RWMModule
            loadImports = liftM mconcat . mapM (liftM fst . getModule . toFilePath . sModuleName . importModule) . getImps

-- Phase 2 (pre-core) transformations.
getProgram :: FilePath -> Cache Core.Program
getProgram fp = do
      (RWMModule ts ds, _) <- getModule fp

      p'     <- pure $ addPrims (ts, ds)

      p''     <- kindCheck
             >=> typeCheck
             >=> neuterPrims
             >=> inline
             >=> reduce
             >=> shiftLambdas
             $ p'

      -- printInfo "___Post_TC___" p''

      p'''   <- liftLambdas p''
      -- _ <- typeCheck p'''

      -- printInfo "___Post_LL___" p'''

      p''''  <- purge p'''
      -- _ <- typeCheck p''''

      -- printInfo "___Post_Purge___" p''''

      p''''' <- toCore p''''

      -- liftIO $ putStrLn "___Core___"
      -- liftIO $ putStrLn $ prettyPrint p'''''

      return p'''''

printInfo :: (MonadIO m, Pretty a, Alpha a) => String -> a -> m ()
printInfo msg p = do
      liftIO $ putStrLn msg
      liftIO $ putStrLn "Free kind vars:\n"
      liftIO $ putStrLn $ concatMap ((++"\n") . prettyPrint) (fv p :: [Name Kind])
      liftIO $ putStrLn "Free type vars:\n"
      liftIO $ putStrLn $ concatMap ((++"\n") . prettyPrint) (fv p :: [Name RWMTy])
      liftIO $ putStrLn "Free tycon vars:\n"
      liftIO $ putStrLn $ concatMap ((++"\n") . prettyPrint) (fv p :: [Name TyConId])
      liftIO $ putStrLn "Free con vars:\n"
      liftIO $ putStrLn $ concatMap ((++"\n") . prettyPrint) (fv p :: [Name DataConId])
      liftIO $ putStrLn "Free exp vars:\n"
      liftIO $ putStrLn $ concatMap ((++"\n") . prettyPrint) (fv p :: [Name RWMExp])
      liftIO $ putStrLn "Program:\n"
      liftIO $ putStrLn $ prettyPrint p

