{-# LANGUAGE MultiParamTypeClasses,DeriveDataTypeable #-}

module ReWire.FrontEnd.Kinds (Kind(..)) where

import ReWire.Scoping
import ReWire.Pretty
import Control.DeepSeq
import Data.Data (Typeable,Data)
import Data.ByteString.Char8 (pack)
import Control.Monad (liftM2)
import Text.PrettyPrint (text,parens,(<+>))

data Kind = Kvar (Id Kind) | Kstar | Kfun Kind Kind | Kmonad
      deriving (Ord,Eq,Show,Typeable,Data)

infixr `Kfun`

instance IdSort Kind where
  idSort _ = pack "K"

instance Alpha Kind where
  aeq' (Kvar i) (Kvar j)           = return (i==j)
  aeq' Kstar Kstar                 = return True
  aeq' (Kfun k1 k2) (Kfun k1' k2') = liftM2 (&&) (aeq' k1 k1') (aeq' k2 k2')
  aeq' Kmonad Kmonad               = return True
  aeq' _ _                         = return False

instance Subst Kind Kind where
  fv (Kvar i)     = [i]
  fv Kstar        = []
  fv (Kfun k1 k2) = fv k1 ++ fv k2
  fv Kmonad       = []
  bv _            = []
  subst' (Kvar i)     = do ml <- query i
                           case ml of
                             Just (Left j)   -> return (Kvar j)
                             Just (Right k') -> return k'
                             Nothing         -> return (Kvar i)
  subst' Kstar        = return Kstar
  subst' (Kfun k1 k2) = liftM2 Kfun (subst' k1) (subst' k2)
  subst' Kmonad       = return Kmonad

instance NFData Kind where
  rnf (Kvar i)     = i `deepseq` ()
  rnf Kstar        = ()
  rnf (Kfun k1 k2) = k1 `deepseq` k2 `deepseq` ()
  rnf Kmonad       = ()

instance Pretty Kind where
  pretty (Kvar x)     = pretty x
  pretty Kstar        = text "*"
  pretty (Kfun a b)   = parens (pretty a <+> text "->" <+> pretty b)
  pretty Kmonad       = text "'nad"
