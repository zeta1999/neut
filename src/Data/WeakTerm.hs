{-# LANGUAGE OverloadedStrings #-}

module Data.WeakTerm where

import Data.Maybe (fromMaybe)
import Numeric.Half

import qualified Data.Text as T

import Data.Basic

data WeakTerm
  = WeakTermTau
  | WeakTermUpsilon Identifier
  | WeakTermPi [IdentifierPlus] WeakTermPlus
  | WeakTermPiIntro [IdentifierPlus] WeakTermPlus
  | WeakTermPiElim WeakTermPlus [WeakTermPlus]
  -- We define Sigma here since n-ary Sigma cannot be defined in the target language.
  -- Although we can `define` it using `notation`, it makes the output of type error
  -- harder to read. Also, by explicitly introducing Sigma as a syntactic construct,
  -- the type inference of Sigma becomes a little more efficient. So we chose to define
  -- it as a syntactic construct.
  -- Of course, we can define 2-ary Sigma and use it to express n-ary Sigma. However,
  -- it sacrifices the performance of output code. I don't choose that way.
  -- Note that this "Sigma" is decomposed into Pi in the standard way that you see in CoC after type inference.
  -- (sigma (x1 A1) ... (xn An))
  | WeakTermSigma [IdentifierPlus]
  -- (sigma-intro type-of-this-sigma-intro e1 ... en)
  -- type-annotation is required when this construct is translated into Pi in elaboration.
  | WeakTermSigmaIntro WeakTermPlus [WeakTermPlus]
  -- (sigma-elimination type-of-e2 ((x1 A1) ... (xn An)) e1 e2)
  -- again, type-annotation is required when this construct is translated into Pi in elaboration.
  | WeakTermSigmaElim WeakTermPlus [IdentifierPlus] WeakTermPlus WeakTermPlus
  -- CBN recursion ~ CBV iteration
  | WeakTermIter IdentifierPlus [IdentifierPlus] WeakTermPlus
  | WeakTermZeta Identifier
  | WeakTermConst Identifier
  | WeakTermConstDecl IdentifierPlus WeakTermPlus
  | WeakTermInt WeakTermPlus Integer
  | WeakTermFloat16 Half
  | WeakTermFloat32 Float
  | WeakTermFloat64 Double
  | WeakTermFloat WeakTermPlus Double
  | WeakTermEnum EnumType
  | WeakTermEnumIntro EnumValue
  | WeakTermEnumElim (WeakTermPlus, WeakTermPlus) [(Case, WeakTermPlus)]
  | WeakTermArray WeakTermPlus ArrayKind -- array n3 u8 ~= n3 -> u8
  | WeakTermArrayIntro ArrayKind [WeakTermPlus]
  | WeakTermArrayElim
      ArrayKind
      [(Identifier, WeakTermPlus)] -- [(x1, return t1), ..., (xn, return tn)] with xi : ti
      WeakTermPlus
      WeakTermPlus
  | WeakTermStruct [ArrayKind] -- e.g. (struct u8 u8 f16 f32 u64)
  | WeakTermStructIntro [(WeakTermPlus, ArrayKind)]
  | WeakTermStructElim [(Identifier, ArrayKind)] WeakTermPlus WeakTermPlus
  deriving (Show, Eq)

type WeakTermPlus = (Meta, WeakTerm)

type SubstWeakTerm = [(Identifier, WeakTermPlus)]

type Hole = Identifier

type IdentifierPlus = (Identifier, WeakTermPlus)

toVar :: Identifier -> WeakTermPlus
toVar x = (emptyMeta, WeakTermUpsilon x)

toIntS :: IntSize -> WeakTermPlus
toIntS size = (emptyMeta, WeakTermEnum $ EnumTypeIntS size)

toIntU :: IntSize -> WeakTermPlus
toIntU size = (emptyMeta, WeakTermEnum $ EnumTypeIntU size)

toValueIntS :: IntSize -> Integer -> WeakTerm
toValueIntS size i = WeakTermEnumIntro $ EnumValueIntS size i

toValueIntU :: IntSize -> Integer -> WeakTerm
toValueIntU size i = WeakTermEnumIntro $ EnumValueIntU size i

f16 :: WeakTermPlus
f16 = (emptyMeta, WeakTermConst "f16")

f32 :: WeakTermPlus
f32 = (emptyMeta, WeakTermConst "f32")

f64 :: WeakTermPlus
f64 = (emptyMeta, WeakTermConst "f64")

varWeakTermPlus :: WeakTermPlus -> [Identifier]
varWeakTermPlus (_, WeakTermTau) = []
varWeakTermPlus (_, WeakTermUpsilon x) = x : []
varWeakTermPlus (_, WeakTermPi xts t) = do
  varWeakTermPlusBindings xts [t]
varWeakTermPlus (_, WeakTermPiIntro xts e) = do
  varWeakTermPlusBindings xts [e]
varWeakTermPlus (_, WeakTermPiElim e es) = do
  let xhs = varWeakTermPlus e
  let yhs = concatMap varWeakTermPlus es
  xhs ++ yhs
varWeakTermPlus (_, WeakTermSigma xts) = varWeakTermPlusBindings xts []
varWeakTermPlus (_, WeakTermSigmaIntro t es) = do
  varWeakTermPlus t ++ concatMap varWeakTermPlus es
varWeakTermPlus (_, WeakTermSigmaElim t xts e1 e2) = do
  let xs = varWeakTermPlus t
  let ys = varWeakTermPlus e1
  let zs = varWeakTermPlusBindings xts [e2]
  xs ++ ys ++ zs
varWeakTermPlus (_, WeakTermIter (x, t) xts e) = do
  varWeakTermPlus t ++ filter (/= x) (varWeakTermPlusBindings xts [e])
varWeakTermPlus (_, WeakTermConst _) = []
varWeakTermPlus (_, WeakTermConstDecl xt e) = varWeakTermPlusBindings [xt] [e]
varWeakTermPlus (_, WeakTermZeta _) = []
varWeakTermPlus (_, WeakTermInt t _) = varWeakTermPlus t
varWeakTermPlus (_, WeakTermFloat16 _) = []
varWeakTermPlus (_, WeakTermFloat32 _) = []
varWeakTermPlus (_, WeakTermFloat64 _) = []
varWeakTermPlus (_, WeakTermFloat t _) = varWeakTermPlus t
varWeakTermPlus (_, WeakTermEnum _) = []
varWeakTermPlus (_, WeakTermEnumIntro _) = []
varWeakTermPlus (_, WeakTermEnumElim (e, t) les) = do
  let xhs = varWeakTermPlus t
  let yhs = varWeakTermPlus e
  let zhs = concatMap (varWeakTermPlus . snd) les
  xhs ++ yhs ++ zhs
varWeakTermPlus (_, WeakTermArray dom _) = varWeakTermPlus dom
varWeakTermPlus (_, WeakTermArrayIntro _ es) = do
  concatMap varWeakTermPlus es
varWeakTermPlus (_, WeakTermArrayElim _ xts d e) =
  varWeakTermPlus d ++ varWeakTermPlusBindings xts [e]
varWeakTermPlus (_, WeakTermStruct {}) = []
varWeakTermPlus (_, WeakTermStructIntro ets) =
  concatMap (varWeakTermPlus . fst) ets
varWeakTermPlus (_, WeakTermStructElim xts d e) = do
  let xs = map fst xts
  varWeakTermPlus d ++ filter (`notElem` xs) (varWeakTermPlus e)

varWeakTermPlusBindings :: [IdentifierPlus] -> [WeakTermPlus] -> [Hole]
varWeakTermPlusBindings [] es = do
  concatMap varWeakTermPlus es
varWeakTermPlusBindings ((x, t):xts) es = do
  let hs1 = varWeakTermPlus t
  let hs2 = varWeakTermPlusBindings xts es
  hs1 ++ filter (/= x) hs2

holeWeakTermPlus :: WeakTermPlus -> [Hole]
holeWeakTermPlus (_, WeakTermTau) = []
holeWeakTermPlus (_, WeakTermUpsilon _) = []
holeWeakTermPlus (_, WeakTermPi xts t) = holeWeakTermPlusBindings xts [t]
holeWeakTermPlus (_, WeakTermPiIntro xts e) = holeWeakTermPlusBindings xts [e]
holeWeakTermPlus (_, WeakTermPiElim e es) =
  holeWeakTermPlus e ++ concatMap holeWeakTermPlus es
holeWeakTermPlus (_, WeakTermSigma xts) = holeWeakTermPlusBindings xts []
holeWeakTermPlus (_, WeakTermSigmaIntro t es) = do
  holeWeakTermPlus t ++ concatMap holeWeakTermPlus es
holeWeakTermPlus (_, WeakTermSigmaElim t xts e1 e2) = do
  let xs = holeWeakTermPlus t
  let ys = holeWeakTermPlus e1
  let zs = holeWeakTermPlusBindings xts [e2]
  xs ++ ys ++ zs
holeWeakTermPlus (_, WeakTermIter (_, t) xts e) =
  holeWeakTermPlus t ++ holeWeakTermPlusBindings xts [e]
holeWeakTermPlus (_, WeakTermZeta h) = h : []
holeWeakTermPlus (_, WeakTermConst _) = []
holeWeakTermPlus (_, WeakTermConstDecl xt e) = holeWeakTermPlusBindings [xt] [e]
holeWeakTermPlus (_, WeakTermInt t _) = holeWeakTermPlus t
holeWeakTermPlus (_, WeakTermFloat16 _) = []
holeWeakTermPlus (_, WeakTermFloat32 _) = []
holeWeakTermPlus (_, WeakTermFloat64 _) = []
holeWeakTermPlus (_, WeakTermFloat t _) = holeWeakTermPlus t
holeWeakTermPlus (_, WeakTermEnum _) = []
holeWeakTermPlus (_, WeakTermEnumIntro _) = []
holeWeakTermPlus (_, WeakTermEnumElim (e, t) les) = do
  let xhs = holeWeakTermPlus e
  let yhs = holeWeakTermPlus t
  let zhs = concatMap (\(_, body) -> holeWeakTermPlus body) les
  xhs ++ yhs ++ zhs
holeWeakTermPlus (_, WeakTermArray dom _) = holeWeakTermPlus dom
holeWeakTermPlus (_, WeakTermArrayIntro _ es) = do
  concatMap holeWeakTermPlus es
holeWeakTermPlus (_, WeakTermArrayElim _ xts d e) =
  holeWeakTermPlus d ++ holeWeakTermPlusBindings xts [e]
holeWeakTermPlus (_, WeakTermStruct {}) = []
holeWeakTermPlus (_, WeakTermStructIntro ets) =
  concatMap (holeWeakTermPlus . fst) ets
holeWeakTermPlus (_, WeakTermStructElim _ d e) = do
  holeWeakTermPlus d ++ holeWeakTermPlus e

holeWeakTermPlusBindings :: [IdentifierPlus] -> [WeakTermPlus] -> [Hole]
holeWeakTermPlusBindings [] es = do
  concatMap holeWeakTermPlus es
holeWeakTermPlusBindings ((_, t):xts) es = do
  holeWeakTermPlus t ++ holeWeakTermPlusBindings xts es

substWeakTermPlus :: SubstWeakTerm -> WeakTermPlus -> WeakTermPlus
substWeakTermPlus _ (m, WeakTermTau) = do
  (m, WeakTermTau)
substWeakTermPlus sub (m, WeakTermUpsilon x) = do
  fromMaybe (m, WeakTermUpsilon x) (lookup x sub)
substWeakTermPlus sub (m, WeakTermPi xts t) = do
  let (xts', t') = substWeakTermPlusBindingsWithBody sub xts t
  (m, WeakTermPi xts' t')
substWeakTermPlus sub (m, WeakTermPiIntro xts body) = do
  let (xts', body') = substWeakTermPlusBindingsWithBody sub xts body
  (m, WeakTermPiIntro xts' body')
substWeakTermPlus sub (m, WeakTermPiElim e es) = do
  let e' = substWeakTermPlus sub e
  let es' = map (substWeakTermPlus sub) es
  (m, WeakTermPiElim e' es')
substWeakTermPlus sub (m, WeakTermSigma xts) = do
  let xts' = substWeakTermPlusBindings sub xts
  (m, WeakTermSigma xts')
substWeakTermPlus sub (m, WeakTermSigmaIntro t es) = do
  let t' = substWeakTermPlus sub t
  let es' = map (substWeakTermPlus sub) es
  (m, WeakTermSigmaIntro t' es')
substWeakTermPlus sub (m, WeakTermSigmaElim t xts e1 e2) = do
  let t' = substWeakTermPlus sub t
  let e1' = substWeakTermPlus sub e1
  let (xts', e2') = substWeakTermPlusBindingsWithBody sub xts e2
  (m, WeakTermSigmaElim t' xts' e1' e2')
substWeakTermPlus sub (m, WeakTermIter (x, t) xts e) = do
  let t' = substWeakTermPlus sub t
  let sub' = filter (\(k, _) -> k /= x) sub
  let (xts', e') = substWeakTermPlusBindingsWithBody sub' xts e
  (m, WeakTermIter (x, t') xts' e')
substWeakTermPlus _ (m, WeakTermConst x) = do
  (m, WeakTermConst x)
substWeakTermPlus sub (m, WeakTermConstDecl (x, t) e) = do
  let t' = substWeakTermPlus sub t
  let e' = substWeakTermPlus (filter (\(k, _) -> k /= x) sub) e
  (m, WeakTermConstDecl (x, t') e')
substWeakTermPlus sub (m, WeakTermZeta s) = do
  fromMaybe (m, WeakTermZeta s) (lookup s sub)
substWeakTermPlus sub (m, WeakTermInt t x) = do
  let t' = substWeakTermPlus sub t
  (m, WeakTermInt t' x)
substWeakTermPlus _ (m, WeakTermFloat16 x) = do
  (m, WeakTermFloat16 x)
substWeakTermPlus _ (m, WeakTermFloat32 x) = do
  (m, WeakTermFloat32 x)
substWeakTermPlus _ (m, WeakTermFloat64 x) = do
  (m, WeakTermFloat64 x)
substWeakTermPlus sub (m, WeakTermFloat t x) = do
  let t' = substWeakTermPlus sub t
  (m, WeakTermFloat t' x)
substWeakTermPlus _ (m, WeakTermEnum x) = do
  (m, WeakTermEnum x)
substWeakTermPlus _ (m, WeakTermEnumIntro l) = do
  (m, WeakTermEnumIntro l)
substWeakTermPlus sub (m, WeakTermEnumElim (e, t) branchList) = do
  let t' = substWeakTermPlus sub t
  let e' = substWeakTermPlus sub e
  let (caseList, es) = unzip branchList
  let es' = map (substWeakTermPlus sub) es
  (m, WeakTermEnumElim (e', t') (zip caseList es'))
substWeakTermPlus sub (m, WeakTermArray dom k) = do
  let dom' = substWeakTermPlus sub dom
  (m, WeakTermArray dom' k)
substWeakTermPlus sub (m, WeakTermArrayIntro k es) = do
  let es' = map (substWeakTermPlus sub) es
  (m, WeakTermArrayIntro k es')
substWeakTermPlus sub (m, WeakTermArrayElim mk xts v e) = do
  let v' = substWeakTermPlus sub v
  let (xts', e') = substWeakTermPlusBindingsWithBody sub xts e
  (m, WeakTermArrayElim mk xts' v' e')
substWeakTermPlus _ (m, WeakTermStruct ts) = do
  (m, WeakTermStruct ts)
substWeakTermPlus sub (m, WeakTermStructIntro ets) = do
  let (es, ts) = unzip ets
  let es' = map (substWeakTermPlus sub) es
  (m, WeakTermStructIntro $ zip es' ts)
substWeakTermPlus sub (m, WeakTermStructElim xts v e) = do
  let v' = substWeakTermPlus sub v
  let sub' = filter (\(k, _) -> k `notElem` map fst xts) sub
  let e' = substWeakTermPlus sub' e
  (m, WeakTermStructElim xts v' e')

substWeakTermPlusBindings ::
     SubstWeakTerm -> [IdentifierPlus] -> [IdentifierPlus]
substWeakTermPlusBindings _ [] = []
substWeakTermPlusBindings sub ((x, t):xts) = do
  let sub' = filter (\(k, _) -> k /= x) sub
  let xts' = substWeakTermPlusBindings sub' xts
  let t' = substWeakTermPlus sub t
  (x, t') : xts'

substWeakTermPlusBindingsWithBody ::
     SubstWeakTerm
  -> [IdentifierPlus]
  -> WeakTermPlus
  -> ([IdentifierPlus], WeakTermPlus)
substWeakTermPlusBindingsWithBody sub [] e = do
  let e' = substWeakTermPlus sub e
  ([], e')
substWeakTermPlusBindingsWithBody sub ((x, t):xts) e = do
  let sub' = filter (\(k, _) -> k /= x) sub
  let (xts', e') = substWeakTermPlusBindingsWithBody sub' xts e
  let t' = substWeakTermPlus sub t
  ((x, t') : xts', e')

univ :: WeakTermPlus
univ = (emptyMeta, WeakTermTau)

univAt :: Meta -> WeakTermPlus
univAt m = (m, WeakTermTau)

toText :: WeakTermPlus -> Identifier
toText (_, WeakTermTau) = "tau"
toText (_, WeakTermUpsilon x) = x
toText (_, WeakTermPi xts t) = do
  let argStr = inParen $ showItems $ map showArg xts
  showCons ["Π", argStr, toText t]
toText (_, WeakTermPiIntro xts e) = do
  let argStr = inParen $ showItems $ map showArg xts
  showCons ["λ", argStr, toText e]
toText (_, WeakTermPiElim e es) = do
  showCons $ map toText $ e : es
toText (_, WeakTermSigma xts)
  | Just (yts, (_, t)) <- splitLast xts = do
    let argStr = inParen $ showItems $ map showArg yts
    showCons ["Σ", argStr, toText t]
  | otherwise = "(product)" -- <> : (product)
toText (_, WeakTermSigmaIntro _ es) = do
  showTuple $ map toText es
toText (_, WeakTermSigmaElim _ xts e1 e2) = do
  let argStr = inParen $ showItems $ map showArg xts
  showCons ["sigma-elimination", argStr, toText e1, toText e2]
toText (_, WeakTermIter (x, _) xts e) = do
  let argStr = inParen $ showItems $ map showArg xts
  showCons ["μ", x, argStr, toText e]
toText (_, WeakTermConst x) = x
toText (_, WeakTermConstDecl xt e) = do
  showCons ["constant-declaration", showArg xt, toText e]
toText (_, WeakTermZeta x) = "?M" <> x
  -- showCons ["zeta", x]
toText (_, WeakTermInt _ a) = T.pack $ show a
toText (_, WeakTermFloat16 a) = T.pack $ show a
toText (_, WeakTermFloat32 a) = T.pack $ show a
toText (_, WeakTermFloat64 a) = T.pack $ show a
toText (_, WeakTermFloat _ a) = T.pack $ show a
toText (_, WeakTermEnum enumType) =
  case enumType of
    EnumTypeLabel l -> l
    EnumTypeIntS size -> "i" <> T.pack (show size)
    EnumTypeIntU size -> "u" <> T.pack (show size)
    EnumTypeNat size -> "n" <> T.pack (show size)
toText (_, WeakTermEnumIntro v) = showEnumValue v
toText (_, WeakTermEnumElim (e, _) les) =
  showCons ["case", toText e, showItems (map showClause les)]
toText (_, WeakTermArray dom _) = toText dom
toText (_, WeakTermArrayIntro _ es) = showArray $ map toText es
toText (_, WeakTermArrayElim _ xts e1 e2) = do
  let argStr = inParen $ showItems $ map showArg xts
  showCons ["array-elimination", argStr, toText e1, toText e2]
toText (_, WeakTermStruct ks) = showCons $ "struct" : map showArrayKind ks
toText (_, WeakTermStructIntro ets) = do
  showStruct $ map (toText . fst) ets
toText (_, WeakTermStructElim xts e1 e2) = do
  let argStr = inParen $ showItems $ map fst xts
  showCons ["struct-elimination", argStr, toText e1, toText e2]

inParen :: T.Text -> T.Text
inParen s = "(" <> s <> ")"

inAngle :: T.Text -> T.Text
inAngle s = "<" <> s <> ">"

inBrace :: T.Text -> T.Text
inBrace s = "{" <> s <> "}"

inBracket :: T.Text -> T.Text
inBracket s = "[" <> s <> "]"

showArg :: (Identifier, WeakTermPlus) -> T.Text
showArg (x, t) = inParen $ x <> " " <> toText t

showClause :: (Case, WeakTermPlus) -> T.Text
showClause (c, e) = inParen $ showCase c <> " " <> toText e

showCase :: Case -> T.Text
showCase (CaseValue v) = showEnumValue v
showCase CaseDefault = "default"

showEnumValue :: EnumValue -> T.Text
showEnumValue (EnumValueLabel l) = l
showEnumValue (EnumValueIntS _ a) = T.pack $ show a
showEnumValue (EnumValueIntU _ a) = T.pack $ show a
showEnumValue (EnumValueNat size a) = T.pack $ "n" ++ show size ++ "-" ++ show a

showArrayKind :: ArrayKind -> T.Text
showArrayKind (ArrayKindIntS size) = T.pack $ "i" ++ show size
showArrayKind (ArrayKindIntU size) = T.pack $ "u" ++ show size
showArrayKind (ArrayKindFloat size) = T.pack $ "f" ++ show (sizeAsInt size)
showArrayKind ArrayKindVoidPtr = "void*" -- shouldn't be used

showItems :: [T.Text] -> T.Text
showItems = T.intercalate " "

showCons :: [T.Text] -> T.Text
showCons = inParen . T.intercalate " "

showTuple :: [T.Text] -> T.Text
showTuple = inAngle . T.intercalate " "

showArray :: [T.Text] -> T.Text
showArray = inBracket . T.intercalate " "

showStruct :: [T.Text] -> T.Text
showStruct = inBrace . T.intercalate " "
