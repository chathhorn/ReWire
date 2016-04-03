{-# LANGUAGE MultiParamTypeClasses,GeneralizedNewtypeDeriving,FlexibleInstances,DeriveDataTypeable
      #-}

module ReWire.Core.Syntax
  ( DataConId(..),TyConId(..),Poly(..)
  , RWCTy(..)
  , RWCExp(..)
  , RWCPat(..)
  , RWCDefn(..)
  , RWCData(..)
  , RWCDataCon(..)
  , RWCProgram(..)
  , mkArrow, arrowRight
  , flattenTyApp,flattenApp,typeOf
  ) where

import ReWire.Pretty
import ReWire.Scoping
import ReWire.Annotation

import Data.ByteString.Char8 (pack)
import Data.Data (Typeable,Data(..))
import Data.List (nub)
import Text.PrettyPrint

---

newtype DataConId = DataConId { deDataConId :: String } deriving (Eq,Ord,Show,Typeable,Data)
newtype TyConId   = TyConId   { deTyConId :: String } deriving (Eq,Ord,Show,Typeable,Data)

data Poly t = [Id t] :-> t
      deriving (Ord,Eq,Show,Typeable,Data)

infixr :->

instance Subst t t => Subst (Poly t) t where
  fv (xs :-> t) = filter (not . (`elem` xs)) (fv t)
  bv (xs :-> t) = xs ++ bv t
  subst' (xs :-> t) = refreshs xs (fv t) $ \ xs' ->
                       do t' <- subst' t
                          return $ xs' :-> t'

instance Alpha (Poly RWCTy) where
  aeq' (xs :-> t) (ys :-> u) = equatings xs ys (return False) (aeq' t u)

instance Pretty DataConId where
  pretty = text . deDataConId

instance Pretty TyConId where
  pretty = text . deTyConId

---

data RWCTy = RWCTyApp Annote RWCTy RWCTy
           | RWCTyCon Annote TyConId
           | RWCTyVar Annote (Id RWCTy)
           | RWCTyComp Annote RWCTy RWCTy -- application of a monad
           deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCTy where
  ann (RWCTyApp a _ _)  = a
  ann (RWCTyCon a _)    = a
  ann (RWCTyVar a _)    = a
  ann (RWCTyComp a _ _) = a

instance IdSort RWCTy where
  idSort _ = pack "T"

instance Subst RWCTy RWCTy where
  fv (RWCTyVar _ x)     = [x]
  fv (RWCTyCon _ _)     = []
  fv (RWCTyApp _ t1 t2) = fv t1 ++ fv t2
  fv (RWCTyComp _ m t)  = fv m ++ fv t
  bv _ = []
  subst' (RWCTyVar an x)  = do ml <- query x
                               case ml of
                                 Just (Left y)  -> return $ RWCTyVar an y
                                 Just (Right e) -> return e
                                 Nothing        -> return $ RWCTyVar an x
  subst' (RWCTyCon an i)     = return $ RWCTyCon an i
  subst' (RWCTyApp an t1 t2) = RWCTyApp an <$> subst' t1 <*> subst' t2
  subst' (RWCTyComp an m t)  = RWCTyComp an <$> subst' m <*> subst' t

instance Alpha RWCTy where
  aeq' (RWCTyApp _ t1 t2) (RWCTyApp _ t1' t2') = (&&) <$> aeq' t1 t1' <*> aeq' t2 t2'
  aeq' (RWCTyCon _ i) (RWCTyCon _ j)           = return $ i == j
  aeq' (RWCTyVar _ x) (RWCTyVar _ y)           = varsaeq x y
  aeq' _ _                                     = return False

instance Pretty RWCTy where
  pretty (RWCTyApp _ (RWCTyApp _ (RWCTyCon _ (TyConId "->")) t1) t2) = ppTyArrowL t1 <+> text "->" <+> pretty t2
    where ppTyArrowL t@(RWCTyApp _ (RWCTyApp _ (RWCTyCon _ (TyConId "->")) _) _) = parens $ pretty t
          ppTyArrowL t                                                           = pretty t
  pretty (RWCTyApp _ t1 t2)  = pretty t1 <+> ppTyAppR t2
  pretty (RWCTyCon _ n)      = text (deTyConId n)
  pretty (RWCTyVar _ n)      = pretty n
  pretty (RWCTyComp _ t1 t2) = pretty t1 <+> ppTyAppR t2

ppTyAppR :: RWCTy -> Doc
ppTyAppR t@RWCTyApp {} = parens $ pretty t
ppTyAppR t             = pretty t

---

data RWCExp = RWCApp Annote RWCExp RWCExp
            | RWCVar Annote (Id RWCExp) RWCTy
            | RWCCon Annote DataConId RWCTy
            | RWCCase Annote RWCExp RWCPat RWCExp RWCExp
            | RWCNativeVHDL Annote String RWCTy
            | RWCError Annote String RWCTy
            deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCExp where
  ann (RWCApp a _ _)        = a
  ann (RWCVar a _ _)        = a
  ann (RWCCon a _ _)        = a
  ann (RWCCase a _ _ _ _)   = a
  ann (RWCNativeVHDL a _ _) = a
  ann (RWCError a _ _)      = a

instance IdSort RWCExp where
  idSort _ = pack "E"

instance Subst RWCExp RWCExp where
  fv (RWCApp _ e1 e2)      = fv e1 ++ fv e2
  fv (RWCVar _ x _)        = [x]
  fv (RWCCon _ _ _)        = []
  fv (RWCCase _ e p e1 e2) = fv e ++ filter (not . (`elem` patvars p)) (fv e1) ++ fv e2
  fv (RWCNativeVHDL _ _ _) = []
  fv (RWCError _ _ _)      = []
  bv (RWCApp _ e1 e2)      = bv e1 ++ bv e2
  bv (RWCVar _ _ _)        = []
  bv (RWCCon _ _ _)        = []
  bv (RWCCase _ e p e1 e2) = bv e ++ patvars p ++ bv e1 ++ bv e2
  bv (RWCNativeVHDL _ _ _) = []
  bv (RWCError _ _ _)      = []
  subst' (RWCApp an e1 e2)      = RWCApp an <$> subst' e1 <*> subst' e2
  subst' (RWCVar an x t)        = do ml <- query x
                                     case ml of
                                       Just (Left y)  -> return $ RWCVar an y t
                                       Just (Right e) -> return e
                                       Nothing        -> return $ RWCVar an x t
  subst' (RWCCon an i t)        = return $ RWCCon an i t
  subst' (RWCCase an e p e1 e2) = RWCCase an <$> subst' e <*> return p <*> subst' e1 <*> subst' e2
  subst' (RWCNativeVHDL an n t) = return $ RWCNativeVHDL an n t
  subst' (RWCError an m t)      = return $ RWCError an m t

instance Subst RWCExp RWCTy where
  fv (RWCApp _ e1 e2)      = fv e1 ++ fv e2
  fv (RWCVar _ _ t)        = fv t
  fv (RWCCon _ _ t)        = fv t
  fv (RWCCase _ e p e1 e2) = fv e ++ fv p ++ fv e1 ++ fv e2
  fv (RWCNativeVHDL _ _ t) = fv t
  fv (RWCError _ _ t)      = fv t
  bv _ = []
  subst' (RWCApp an e1 e2)      = RWCApp an <$> subst' e1 <*> subst' e2
  subst' (RWCVar an x t)        = RWCVar an x <$> subst' t
  subst' (RWCCon an i t)        = RWCCon an i <$> subst' t
  subst' (RWCCase an e p e1 e2) = RWCCase an <$> subst' e <*> subst' p <*> subst' e1 <*> subst' e2
  subst' (RWCNativeVHDL an n t) = RWCNativeVHDL an n <$> subst' t
  subst' (RWCError an m t)      = RWCError an m <$> subst' t

instance Alpha RWCExp where
  aeq' (RWCApp _ e1 e2) (RWCApp _ e1' e2')             = (&&) <$> aeq' e1 e1' <*> aeq' e2 e2'
  aeq' (RWCVar _ x _) (RWCVar _ y _)                   = varsaeq x y
  aeq' (RWCCon _ i _) (RWCCon _ j _)                   = return $ i == j
  aeq' (RWCCase _ e p e1 e2) (RWCCase _ e' p' e1' e2') = (&&) <$> aeq' e e' <*> ((&&) <$> equatingPats p p' (aeq' e1 e1') <*> aeq' e2 e2')
  aeq' (RWCNativeVHDL _ n t) (RWCNativeVHDL _ n' t')   = return $ n == n'
  aeq' (RWCError _ m _) (RWCError _ m' _)              = return $ m == m'
  aeq' _ _                                             = return False

instance Pretty RWCExp where
  pretty (RWCApp _ e1 e2)      = parens $ hang (pretty e1) 4 (pretty e2)
  pretty (RWCCon _ n _)        = text (deDataConId n)
  pretty (RWCVar _ n _)        = pretty n
  pretty (RWCCase _ e p e1 e2) = parens $
                                 foldr ($+$) empty
                                   [ text "case" <+> pretty e <+> text "of"
                                   , nest 4 (braces $ vcat $ punctuate (space <> text ";" <> space)
                                     [ parens (pretty p) <+> text "->" <+> pretty e1
                                     , text "_" <+> text "->" <+> pretty e2
                                     ])
                                   ]
  pretty (RWCNativeVHDL _ n _) = parens (text "nativeVHDL" <+> doubleQuotes (text n))
  pretty (RWCError _ m _)      = parens (text "primError" <+> doubleQuotes (text m))

---

data RWCPat = RWCPatCon Annote DataConId [RWCPat]
            | RWCPatVar Annote (Id RWCExp) RWCTy
            deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCPat where
  ann (RWCPatCon a _ _)   = a
  ann (RWCPatVar a _ _)   = a

patvars :: RWCPat -> [Id RWCExp]
patvars (RWCPatCon _ _ ps)  = concatMap patvars ps
patvars (RWCPatVar _ x _)   = [x]

equatingPats :: RWCPat -> RWCPat -> AlphaM Bool -> AlphaM Bool
equatingPats (RWCPatCon _ i ps) (RWCPatCon _ j ps') k
  | i == j    = equatingsPats ps ps' k
  | otherwise = return False
     where equatingsPats ps ps' k | length ps /= length ps' = return False
                                  | otherwise               = foldr (uncurry equatingPats) k (zip ps ps')
equatingPats (RWCPatVar _ x _) (RWCPatVar _ y _) k                  = equating x y k
equatingPats _ _ _                                                  = return False

instance Subst RWCPat RWCTy where
  fv (RWCPatCon _ _ ps)  = concatMap fv ps
  fv (RWCPatVar _ _ t)   = fv t
  bv _ = []
  subst' (RWCPatCon an i ps)  = RWCPatCon an i <$> subst' ps
  subst' (RWCPatVar an x t)   = RWCPatVar an x <$> subst' t

instance Pretty RWCPat where
  pretty (RWCPatCon _ n ps)        = parens (text (deDataConId n) <+> hsep (map pretty ps))
  pretty (RWCPatVar _ n _)         = pretty n

---

data RWCDefn = RWCDefn { defnAnnote :: Annote,
                         defnName   :: Id RWCExp,
                         defnPolyTy :: Poly RWCTy,
                         defnVars   :: [Id RWCExp],
                         defnBody   :: RWCExp }
               deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCDefn where
  ann (RWCDefn a _ _ _ _) = a

instance Subst RWCDefn RWCExp where
  fv (RWCDefn _ n _ vs e) = filter (not . (`elem` n : vs)) (fv e)
  bv (RWCDefn _ n _ vs e) = vs ++ n : bv e
  -- subst' (RWCDefn an n pt e) = refresh n (fv e) $ \ n' ->
  --                              do e' <- subst' e
  --                                 return $ RWCDefn an n' pt e'

instance Subst RWCDefn RWCTy where
  fv (RWCDefn _ _ pt _ e) = fv pt ++ fv e
  bv (RWCDefn _ _ pt _ _) = bv pt
  -- subst' (RWCDefn an n (xs :-> t) e) = refreshs xs (fv t ++ fv e) $ \ xs' ->
  --                                      do t' <- subst' t
  --                                         e' <- subst' e
  --                                         return $ RWCDefn an n (xs' :-> t') e'

instance Pretty RWCDefn where
  pretty (RWCDefn _ n (_ :-> ty) vs e) = foldr ($+$) empty
                                           (  [pretty n <+> text "::" <+> pretty ty]
                                           ++ [pretty n <+> hsep (map pretty vs) <+> text "=", nest 4 $ pretty e])

---

data RWCData = RWCData { dataAnnote :: Annote,
                         dataName   :: TyConId,
                         dataTyVars :: [Id RWCTy],
                         dataCons   :: [RWCDataCon] }
               deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCData where
  ann (RWCData a _ _ _) = a

-- FIXME: just ignoring the kind here
instance Pretty RWCData where
  pretty (RWCData _ n tvs dcs) = foldr ($+$) empty
                                     [text "data" <+> text (deTyConId n) <+> hsep (map pretty tvs) <+> (if null (map pretty dcs) then empty else char '='),
                                     nest 4 (hsep (punctuate (char '|') $ map pretty dcs))]

---

data RWCDataCon = RWCDataCon Annote DataConId [RWCTy]
                  deriving (Ord,Eq,Show,Typeable,Data)

instance Annotated RWCDataCon where
  ann (RWCDataCon a _ _) = a

instance Pretty RWCDataCon where
  pretty (RWCDataCon _ n ts) = text (deDataConId n) <+> hsep (map pretty ts)

---

data RWCProgram = RWCProgram { dataDecls  :: [RWCData],
                               defns      :: [RWCDefn] }
                  deriving (Ord,Eq,Show,Typeable,Data)

instance Monoid RWCProgram where
  mempty = RWCProgram mempty mempty
  mappend (RWCProgram ts vs) (RWCProgram ts' vs') = RWCProgram (nub $ ts ++ ts') $ nub $ vs ++ vs'

instance Pretty RWCProgram where
  pretty p = ppDataDecls (dataDecls p) $+$ ppDefns (defns p)
    where ppDefns = foldr ($+$) empty . map pretty
          ppDataDecls = foldr ($+$) empty . map pretty

---

flattenTyApp :: RWCTy -> [RWCTy]
flattenTyApp (RWCTyApp _ t1 t2) = flattenTyApp t1 ++ [t2]
flattenTyApp t                  = [t]

flattenApp :: RWCExp -> [RWCExp]
flattenApp (RWCApp _ e e') = flattenApp e++[e']
flattenApp e               = [e]

mkArrow :: RWCTy -> RWCTy -> RWCTy
mkArrow t = RWCTyApp noAnn (RWCTyApp noAnn (RWCTyCon noAnn (TyConId "->")) t)

infixr `mkArrow`

arrowRight :: RWCTy -> RWCTy
arrowRight (RWCTyApp _ (RWCTyApp _ (RWCTyCon _ (TyConId "->")) _) t2) = t2
arrowRight t                                                          = error $ "arrowRight: got non-arrow type: " ++ show t

typeOf :: RWCExp -> RWCTy
typeOf (RWCApp _ e _)        = arrowRight (typeOf e)
typeOf (RWCVar _ _ t)        = t
typeOf (RWCCon _ _ t)        = t
typeOf (RWCCase _ _ _ e _)   = typeOf e
typeOf (RWCNativeVHDL _ _ t) = t
typeOf (RWCError _ _ t)      = t
