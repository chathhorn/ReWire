-- Interactive environment for transforming ReWire Core programs.

module ReWire.Core.Interactive (TransCommand,trans) where

--import Prelude hiding (sequence,mapM)
import ReWire.Core.Syntax
import Control.Monad -- hiding (sequence,mapM)
import Data.List (intercalate)
--import Control.Monad.Reader hiding (sequence,mapM)
--import Control.Monad.Identity hiding (sequence,mapM)
--import Data.Traversable (sequence,mapM)
--import Data.Maybe (catMaybes,isNothing,fromJust)
import Data.Char
import ReWire.Core.Expand (cmdExpand)
import ReWire.Core.Reduce (cmdReduce)
import ReWire.Core.Purge (cmdPurge,cmdOccurs)
import ReWire.Core.ToPreHDL (cmdToCFG,cmdToPre,cmdToVHDL,cmdToSCFG,cmdToPreG)
import ReWire.Core.Uniquify (cmdUniquify)
import ReWire.Core.DeUniquify (cmdDeUniquify)
import ReWire.Core.Types
import ReWire.Pretty
import System.IO

-- Table of available commands.
type CommandTable = [(String,TransCommand)]

cmdPrint :: TransCommand
cmdPrint _ p = (Nothing,Just $ prettyPrint p)

cmdHelp :: TransCommand
cmdHelp _ _ = (Nothing,Just (intercalate ", " (map fst cmdTable)))

--cmdPrintDebug :: TransCommand
--cmdPrintDebug _ p = (Nothing,Just (show $ pp p))

cmdPrintShow :: TransCommand
cmdPrintShow _ p = (Nothing,Just (show p))

-- Here are the commands available.
cmdTable :: CommandTable
cmdTable = [
            (":p",cmdPrint),
--            (":pd",cmdPrintDebug),
            (":ps",cmdPrintShow),
            (":?",cmdHelp),
            ("uniquify",cmdUniquify),
            ("deuniquify",cmdDeUniquify),
            ("expand",cmdExpand),
            ("reduce",cmdReduce),
            ("purge",cmdPurge),
--            ("ll",lambdaLift),
--            ("status",cmdStatus),
            ("occurs",cmdOccurs),
--            ("uses", cmdUses),
--            ("checknf",cmdCheckNF),
            ("tovhdl",cmdToVHDL),
            ("toscfg",cmdToSCFG),
            ("tocfg",cmdToCFG),
            ("topre",cmdToPre),
            ("topreg",cmdToPreG)
--            ("topseudo",cmdToPseudo)
           ]

-- The "repl" for the translation environment.
trans :: RWCProgram -> IO ()
trans m = do print (pretty m)
             loop m
   where loop m = do putStr "> "
                     hFlush stdout
                     n <- getLine
                     let (cmd,n') = break isSpace n
                         args     = dropWhile isSpace n'
                     unless (cmd == ":q") $
                         case lookup cmd cmdTable of
                               Just f  -> do let (mp,ms) = f args m
                                             case ms of
                                               Just s  -> putStrLn s >> writeFile "rewire.cmd.out" s
                                               Nothing -> return ()
                                             case mp of
                                               Just m' -> do print (pretty m')
                                                             loop m'
                                               Nothing -> loop m
                               Nothing -> do if not (null n) then putStrLn $ "Invalid command: " ++ cmd else return ()
                                             loop m
