module ReWire.CoreParser where

-- FIXME throughout: at any point where "identifier" occurs, we probably want
-- to reject either Constructors or variables.

import ReWire.Core
import Text.Parsec
import Text.Parsec.Language as L
import qualified Text.Parsec.Token as T
import Unbound.LocallyNameless
import Data.Char

rwcDef :: T.LanguageDef st
rwcDef = T.LanguageDef { T.commentStart    = "{-",
                         T.commentEnd      = "-}",
                         T.commentLine     = "--",
                         T.nestedComments  = True,
                         T.identStart      = letter,
                         T.identLetter     = letter,
                         T.opStart         = fail "no operators",
                         T.opLetter        = fail "no operators",
                         T.reservedNames   = ["data","of","end","def","is","case","instance","newtype"],
                         T.reservedOpNames = ["="],
                         T.caseSensitive   = True }

lexer = T.makeTokenParser rwcDef

identifier     = T.identifier lexer
reserved       = T.reserved lexer
operator       = T.operator lexer
reservedOp     = T.reservedOp lexer
charLiteral    = T.charLiteral lexer
stringLiteral  = T.stringLiteral lexer
natural        = T.natural lexer
integer        = T.integer lexer
float          = T.float lexer
naturalOrFloat = T.naturalOrFloat lexer
decimal        = T.decimal lexer
hexadecimal    = T.hexadecimal lexer
octal          = T.octal lexer
symbol         = T.symbol lexer
lexeme         = T.lexeme lexer
whiteSpace     = T.whiteSpace lexer
parens         = T.parens lexer
braces         = T.braces lexer
angles         = T.angles lexer
brackets       = T.brackets lexer
squares        = T.squares lexer
semi           = T.semi lexer
comma          = T.comma lexer
colon          = T.colon lexer
dot            = T.dot lexer
semiSep        = T.semiSep lexer
semiSep1       = T.semiSep1 lexer
commaSep       = T.commaSep lexer
commaSep1      = T.commaSep1 lexer

{-
constructor = try (do n <- identifier
                      if isUpper (head n)
                        then return n
                        else fail "name was not a constructor")
          <?> "constructor name"
-}

constraint = do n  <- identifier
                ts <- angles (commaSep ty)
                return (RWCConstraint n ts)

ty = do (t1,t2) <- parens (do t1 <- ty
                              t2 <- ty
                              return (t1,t2))
        return (RWCTyApp t1 t2)
 <|> do n <- identifier
        if isUpper (head n)
           then return (RWCTyCon n)
           else return (RWCTyVar (s2n n))

-- FIXME: the "try" backs off too far here, error messages are lousy.
-- Instead combine app and lambda cases, look ahead for \
expr = try (do (e1,e2) <- parens (do e1 <- expr
                                     e2 <- expr
                                     return (e1,e2))
               t       <- angles ty
               return (RWCApp t e1 e2))
   <|> (do n <- identifier
           t <- angles ty
           if isUpper (head n)
              then return (RWCCon t n)
              else return (RWCVar t (s2n n)))
   <|> (do (n,t,e) <- parens (do reservedOp "\\"
                                 n <- identifier -- FIXME: check caps
                                 t <- angles ty
                                 reservedOp "->"
                                 e <- expr
                                 return (n,t,e))
           t'      <- angles ty
           return (RWCLam t' (bind (s2n n,embed t) e)))


defn = do reserved "def"
          n   <- identifier
          tvs <- angles (many identifier)
          cs  <- angles (many constraint)
          ty  <- angles ty
          reserved "is"
          e    <- expr
          reserved "end"
          return (RWCDefn n (bind (map s2n tvs) (cs,ty,e)))

datacon = do n  <- identifier
             ts <- many (angles ty)
             return (RWCDataCon n ts)

datadecl = do reserved "data"
              n   <- identifier
              tvs <- angles (many identifier)
              reserved "of"
              dcs <- many datacon
              reserved "end"
              return (RWCData n (bind (map s2n tvs) dcs))

newtypecon = do n <- identifier
                t <- angles ty
                return (RWCNewtypeCon n t)

newtypedecl = do reserved "newtype"
                 n   <- identifier
                 tvs <- angles (many identifier)
                 reserved "of"
                 nc  <- newtypecon
                 reserved "end"
                 return (RWCNewtype n (bind (map s2n tvs) nc))

instancedecl = do reserved "instance"
                  n   <- identifier
                  tvs <- angles (many identifier)
                  cs  <- angles (commaSep constraint)
                  t   <- ty
                  reserved "end"
                  return (RWCInstance n (bind (map s2n tvs) (cs,t)))

rwcProg = do dds <- many datadecl
             nds <- many newtypedecl
             ids <- many instancedecl
             ds  <- many defn
             return (RWCProg { dataDecls    = dds,
                               newtypeDecls = nds,
                               instances    = ids,
                               defns        = ds })