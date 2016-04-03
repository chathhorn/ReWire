{-# LANGUAGE LambdaCase #-}
module ReWire.FrontEnd.ToCore (toCore) where

import ReWire.Core.Syntax hiding (typeOf)
import ReWire.FrontEnd.PrimBasis
import ReWire.FrontEnd.Syntax
import ReWire.Scoping

import Data.Monoid ((<>))

toCore :: Monad m => RWMProgram -> m RWCProgram
toCore p = toCore' $ p <> primBasis
      where toCore' :: (Monad m, Functor m, Applicative m) => RWMProgram -> m RWCProgram
            toCore' (RWMProgram datas funs) = RWCProgram <$> mapM transData datas <*> mapM transFun funs

transData :: Monad m => RWMData -> m RWCData
transData (RWMData an t ts _ cs) = return $ RWCData an t ts cs

transFun :: Monad m => RWMDefn -> m RWCDefn
transFun (RWMDefn an n ty _ vs e) = RWCDefn an <$> transId n <*> return ty <*> mapM transId vs <*> transExp e

transId :: Monad m => Id RWMExp -> m (Id RWCExp)
transId (Id x y) = return $ Id x y

transExp :: Monad m => RWMExp -> m RWCExp
transExp = \ case
      RWMApp an e1 e2       -> RWCApp an <$> transExp e1 <*> transExp e2
      RWMVar an x t         -> RWCVar an <$> transId x <*> return t
      RWMCon an d t         -> return $ RWCCon an d t
      RWMCase an e1 p e2 e3 -> RWCCase an <$> transExp e1 <*> transPat p <*> transExp e2 <*> transExp e3
      RWMNativeVHDL an s e  -> return $ RWCNativeVHDL an s $ typeOf e
      RWMError an s t       -> return $ RWCError an s t
      _                     -> error "ToCore: unsupported expression"

transPat :: Monad m => RWMPat -> m RWCPat
transPat = \ case
      RWMPatCon an d ps  -> RWCPatCon an d <$> mapM transPat ps
      RWMPatVar an x t   -> RWCPatVar an <$> transId x <*> return t
