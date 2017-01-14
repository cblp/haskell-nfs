-- | XDR Parser for .x files, as per RFC4506

{-# LANGUAGE TupleSections #-}
module Data.XDR.Parse
  ( Binding(..)
  , Scope
  , parseFile
  ) where

import           Control.Applicative ((<|>))
import           Control.Arrow (second)
import           Control.Monad (void, liftM2)
import qualified Data.ByteString.Lazy.Char8 as BSLC
import           Data.Char (digitToInt, isLower, isUpper, toLower, toUpper)
import           Data.Functor.Identity (Identity)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes, mapMaybe)
import qualified Data.Set as Set
import qualified Text.Parsec as P
import qualified Text.Parsec.Token as PT

import qualified Data.XDR.Types as XDR
import           Data.XDR.Specification hiding (arrayLength)

data Binding = Binding
  { bindingInitCaseConflict :: !Bool -- ^Same name as another identifier modulo first character case
  , bindingDefinition :: !DefinitionBody
  }
  deriving (Show)

type Scope = Map.Map Identifier Binding
type Stream = BSLC.ByteString
type Parser = P.Parsec Stream Scope

tupleM :: Monad m => m a -> m b -> m (a, b)
tupleM = liftM2 (,)

baseScope :: Scope
baseScope = Map.fromList $
  ("bool",        Binding False $ TypeDef $ TypeSingle $ TypeEnum $ EnumBody $ boolValues)
  : map (second $ Binding False . TypeDef . TypeSingle)
    [ ("int",       TypeInt)
    , ("unsigned",  TypeUnsignedInt)
    , ("hyper",     TypeHyper)
    , ("float",     TypeFloat)
    , ("double",    TypeDouble)
    , ("quadruple", TypeQuadruple)
    ]
  ++ map (second $ Binding False . Constant . toInteger) boolValues

addScope :: Definition -> Parser ()
addScope (Definition i b) = do
  case b of
    TypeDef t -> void $ resolveTypeDescriptor t
    _ -> return ()
  s <- P.getState
  case Map.insertLookupWithKey (\_ -> const) i (Binding (Map.member (toggleInitCase i) s) b) s of
    (Nothing, s') -> P.putState s'
    _ -> fail $ "duplicate identifier: " ++ show i

token :: PT.GenTokenParser Stream a Identity
token = PT.makeTokenParser PT.LanguageDef
  { PT.commentStart    = "/*"
  , PT.commentEnd      = "*/"
  , PT.commentLine     = "%"
  , PT.nestedComments  = False
  , PT.identStart      = P.letter
  , PT.identLetter     = P.alphaNum <|> P.char '_'
  , PT.opStart         = error "token op"
  , PT.opLetter        = error "token op"
  , PT.reservedNames   =
    [ "bool"
    , "case"
    , "const"
    , "default"
    , "double"
    , "quadruple"
    , "enum"
    , "float"
    , "hyper"
    , "int"
    , "opaque"
    , "string"
    , "struct"
    , "switch"
    , "typedef"
    , "union"
    , "unsigned"
    , "void"
    ]
  , PT.reservedOpNames = []
  , PT.caseSensitive   = True
  }

reserved :: String -> Parser ()
reserved = PT.reserved token

identifier :: Parser Identifier
identifier = PT.identifier token

endSemi1 :: Parser a -> Parser [a]
endSemi1 p = p `P.endBy1` PT.semi token

arrayLength, variableArrayLength :: Parser ArrayLength
variableArrayLength =
  VariableArray <$> PT.angles token (P.option maxLength value)
arrayLength =
  FixedArray    <$> PT.brackets token value
  <|> variableArrayLength

declaration :: Parser Declaration
declaration =
      typeDeclaration
  <|> opaqueDeclaration
  <|> stringDeclaration
  where
  typeDeclaration = do
    t <- typeSpecifier
    Declaration
        <$> (PT.symbol token "*" *> identifier)
        <*> pure (TypeOptional t)
      <|> Declaration
        <$> identifier
        <*> (TypeArray t <$> arrayLength <|> return (TypeSingle t))
  opaqueDeclaration =
    Declaration
      <$> (reserved "opaque" *> identifier)
      <*> (TypeOpaque <$> arrayLength)
  stringDeclaration =
    Declaration
      <$> (reserved "string" *> identifier)
      <*> (TypeString <$> variableArrayLength)

voidableDeclaration :: Parser OptionalDeclaration
voidableDeclaration =
      Just <$> declaration
  <|> Nothing <$ reserved "void"

constant :: Parser Integer
constant = (PT.lexeme token $
  nat <|> P.char '-' *> (negate <$> dec))
    P.<?> "constant" where
  nat = P.char '0' *> (P.oneOf "xX" *> number 16 P.hexDigit <|> number 8 P.octDigit <|> return 0) <|> dec
  dec = number 10 P.digit
  number base digit = foldl (\x d -> base*x + toInteger (digitToInt d)) 0 <$> P.many1 digit

value :: Integral n => Parser n
value = fi =<< constant <|> do
  v <- identifier
  s <- P.getState
  case Map.lookup v s of
    Just (Binding _ (Constant n)) -> return n
    _ -> fail $ "undefined constant: " ++ show v
  where
  fi n
    | n == toInteger n' = return n'
    | otherwise = fail "invalid constant"
    where n' = fromInteger n

typeSpecifier :: Parser TypeSpecifier
typeSpecifier = P.choice
  [ TypeInt        <$ reserved "int"
  , TypeHyper      <$ reserved "hyper"
  , reserved "unsigned" *> (
        TypeUnsignedInt   <$ reserved "int"
    <|> TypeUnsignedHyper <$ reserved "hyper"
    <|> return TypeUnsignedInt)
  , TypeFloat      <$ reserved "float"
  , TypeDouble     <$ reserved "double"
  , TypeQuadruple  <$ reserved "quadruple"
  , TypeBool       <$ reserved "bool"
  , reserved "enum"  *> (TypeEnum   <$> enumBody   <|> typeIdentifier)
  , reserved "struct"*> (TypeStruct <$> structBody <|> typeIdentifier)
  , reserved "union" *> (TypeUnion  <$> unionBody  <|> typeIdentifier)
  , typeIdentifier
  ] where
  typeIdentifier = TypeIdentifier <$> identifier

checkUnique :: (Ord k, Show k) => String -> [k] -> Parser (Set.Set k)
checkUnique t = ui Set.empty where
  ui m [] = return m
  ui m (k:l)
    | Set.member k m = fail $ "duplicate " ++ t ++ ": " ++ show k
    | otherwise = ui (Set.insert k m) l

enumBody :: Parser EnumBody
enumBody = do
  l <- PT.braces token $ PT.commaSep1 token $
    tupleM identifier (PT.symbol token "=" *> value)
  _ <- checkUnique "enum identifier" $ fst <$> l
  _ <- checkUnique "enum value" $ snd <$> l
  mapM_ (\(i, v) -> addScope $ Definition i $ Constant $ toInteger v) l
  return $ EnumBody l

structBody :: Parser StructBody
structBody = do
  l <- PT.braces token $ catMaybes <$> endSemi1 voidableDeclaration
  _ <- checkUnique "struct member" $ declarationIdentifier <$> l
  return $ StructBody l

unionBody :: Parser UnionBody
unionBody = do
  reserved "switch"
  d <- PT.parens token declaration
  r <- resolveTypeDescriptor $ declarationType d
  p <- case r of
    TypeSingle TypeInt -> return $ toInteger <$> (value :: Parser XDR.Int)
    TypeSingle TypeUnsignedInt -> return $ toInteger <$> (value :: Parser XDR.UnsignedInt)
    TypeSingle TypeBool -> return $ valid boolValues =<< value
    TypeSingle (TypeEnum (EnumBody v)) -> return $ valid v =<< value
    _ -> fail "invalid discriminant declaration"
  PT.braces token $ do
    l <- endSemi1 (tupleM
      (P.many1 $ reserved "case" *> p <* PT.colon token)
      voidableDeclaration)
    _ <- checkUnique "union member" $ mapMaybe (fmap declarationIdentifier . snd) l
    _ <- checkUnique "union case" $ fst =<< l
    f <- P.optionMaybe $ reserved "default" *> PT.colon token *> voidableDeclaration <* PT.semi token
    return $ UnionBody d [ (c, b) | (cs, b) <- l, c <- cs ] f
  where
  valid l n
    | any ((n ==) . snd) l = return $ toInteger n
    | otherwise = fail "invalid enum value"

-- |Expand 'TypeSingle' 'TypeIdentifier'
resolveTypeDescriptor :: TypeDescriptor -> Parser TypeDescriptor
resolveTypeDescriptor (TypeSingle (TypeIdentifier i)) = do
  s <- P.getState
  case Map.lookup i s of
    Just (Binding _ (TypeDef t)) -> resolveTypeDescriptor t
    _ -> fail $ "undefined type: " ++ show i
resolveTypeDescriptor d = return d

def :: Parser Definition
def = constantDef <|> typeDef where
  constantDef = Definition
    <$> (reserved "const" *> identifier)
    <*> (PT.symbol token "=" *> (Constant <$> constant))
  typeDef =
        reserved "typedef" *> (declDef <$> declaration)
    <|> Definition <$> (reserved "enum"   *> identifier) <*> (TypeDef . TypeSingle . TypeEnum   <$> enumBody)
    <|> Definition <$> (reserved "struct" *> identifier) <*> (TypeDef . TypeSingle . TypeStruct <$> structBody)
    <|> Definition <$> (reserved "union"  *> identifier) <*> (TypeDef . TypeSingle . TypeUnion  <$> unionBody)
  declDef (Declaration i t) = Definition i $ TypeDef t

toggleInitCase :: String -> String
toggleInitCase (c:s)
  | isUpper c = toLower c:s
  | isLower c = toUpper c:s
toggleInitCase s = s

definition :: Parser Definition
definition = do
  d <- def
  addScope d
  return d

specification :: Parser Specification
specification = endSemi1 definition

file :: Parser (Specification, Scope)
file = PT.whiteSpace token *> tupleM specification P.getState <* P.eof

parseFile :: FilePath -> IO (Either P.ParseError (Specification, Scope))
parseFile f = P.runParser file baseScope f <$> BSLC.readFile f
