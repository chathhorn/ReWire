module ReWire.Main (main) where

import ReWire.Core.Inline
import ReWire.Core.Interactive
import ReWire.Core.Syntax
import ReWire.Core.ToPreHDL (cfgFromRW,eu)
import ReWire.FrontEnd
import ReWire.FrontEnd.LoadPath
import ReWire.PreHDL.CFG (mkDot,gather,linearize,cfgToProg)
import ReWire.PreHDL.ElimEmpty (elimEmpty)
import ReWire.PreHDL.GotoElim (gotoElim)
import ReWire.PreHDL.ToVHDL (toVHDL)
import ReWire.Pretty

import Control.Monad (when,unless)
import Data.List (intercalate)
import Data.List.Split (splitOn)
import System.Console.GetOpt
import System.Environment
import System.Exit
import System.IO

data Flag = FlagCFG String
          | FlagLCFG String
          | FlagPre String
          | FlagGPre String
          | FlagO String
          | FlagI
          | FlagD
          | FlagLoadPath String
          deriving (Eq,Show)

options :: [OptDescr Flag]
options =
 [ Option ['d'] ["debug"]    (NoArg FlagD)
                             "dump miscellaneous debugging information"
 , Option ['i'] []           (NoArg FlagI)
                             "run in interactive mode (overrides all other options except --loadpath)"
 , Option ['o'] []           (ReqArg FlagO "filename.vhd")
                             "generate VHDL"
 , Option []    ["loadpath"] (ReqArg FlagLoadPath "dir1,dir2,...")
                             "additional directories for loadpath"
 , Option []    ["cfg"]      (ReqArg FlagCFG "filename.dot")
                             "generate control flow graph before linearization"
 , Option []    ["lcfg"]     (ReqArg FlagLCFG "filename.dot")
                             "generate control flow graph after linearization"
 , Option []    ["pre"]      (ReqArg FlagPre "filename.phdl")
                             "generate PreHDL before goto elimination"
 , Option []    ["gpre"]     (ReqArg FlagGPre "filename.phdl")
                             "generate PreHDL after goto elimination"
 ]

exitUsage :: IO ()
exitUsage = hPutStr stderr (usageInfo "Usage: rwc [OPTION...] <filename.rw>" options) >> exitFailure

runFE :: Bool -> LoadPath -> FilePath -> IO RWCProgram
runFE fDebug lp filename = do
  res_m <- loadProgram lp filename

  case res_m of
    Left e ->
       hPrint stderr e >> exitFailure
    Right m      -> do

      when fDebug $ do
        putStrLn "parse finished"
        writeFile "show.out" (show m)
        putStrLn "show out finished"
        writeFile "Debug.hs" (prettyPrint m)
        putStrLn "debug out finished"

      return m

main :: IO ()
main = do args                       <- getArgs

          let (flags,filenames,errs) =  getOpt Permute options args

          unless (null errs) (mapM_ (hPutStrLn stderr) errs >> exitUsage)

          when (length filenames /= 1) (hPutStrLn stderr "exactly one source file must be specified" >> exitUsage)

          let isActFlag (FlagCFG _)  = True
              isActFlag (FlagLCFG _) = True
              isActFlag (FlagPre _)  = True
              isActFlag (FlagGPre _) = True
              isActFlag (FlagO _)    = True
              isActFlag FlagI        = True
              isActFlag _            = False

          unless (any isActFlag flags) (hPutStrLn stderr "must specify at least one of -i, -o, --cfg, --lcfg, --pre, or --gpre" >> exitUsage)

          let filename                             =  head filenames
              getLoadPathEntries (FlagLoadPath ds) =  splitOn "," ds
              getLoadPathEntries _                 =  []
              userLP                               =  concatMap getLoadPathEntries flags
          systemLP                                 <- getSystemLoadPath
          let lp                                   =  userLP ++ systemLP

          when (FlagD `elem` flags) $
            putStrLn ("loadpath: " ++ intercalate "," lp)

          m_ <- runFE (FlagD `elem` flags) lp filename

          if FlagI `elem` flags then trans m_
          else
            case inline m_ of
              Nothing -> hPutStrLn stderr "Inlining failed" >> exitFailure
              Just m  -> do
                let cfg     = cfgFromRW m
                    cfgDot  = mkDot (gather (eu cfg))
                    lcfgDot = mkDot (gather (linearize cfg))
                    pre     = cfgToProg cfg
                    gpre    = gotoElim pre
                    vhdl    = toVHDL (elimEmpty gpre)
                    doDump (FlagCFG f)  = writeFile f cfgDot
                    doDump (FlagLCFG f) = writeFile f lcfgDot
                    doDump (FlagPre f)  = writeFile f $ show pre
                    doDump (FlagGPre f) = writeFile f $ show gpre
                    doDump (FlagO f)    = writeFile f vhdl
                    doDump _            = return ()
                mapM_ doDump flags
