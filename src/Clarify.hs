{-# LANGUAGE OverloadedStrings #-}

--
-- clarification == polarization + closure conversion + linearization (+ rename, for LLVM IR)
--
module Clarify
  ( clarify
  ) where

import Control.Monad.Except
import Control.Monad.State
import Data.List (nubBy)

import qualified Data.HashMap.Strict as Map
import qualified Data.Text as T

import Clarify.Closure
import Clarify.Sigma
import Clarify.Utility
import Data.Basic
import Data.Code
import Data.Env
import Data.Term
import Reduce.Term

clarify :: TermPlus -> WithEnv CodePlus
clarify (m, TermTau _) = do
  v <- cartesianImmediate m
  return (m, CodeUpIntro v)
clarify (m, TermUpsilon x) = return (m, CodeUpIntro (m, DataUpsilon x))
clarify (m, TermPi {}) = do
  returnClosureType m
clarify lam@(m, TermPiIntro mxts e) = do
  let (_, xs, ts) = unzip3 mxts
  let xts = zip xs ts
  forM_ xts $ uncurry insTypeEnv'
  e' <- clarify e
  fvs <- chainTermPlus lam
  retClosure Nothing fvs m mxts e'
clarify (m, TermPiElim e es) = do
  es' <- mapM clarifyPlus es
  e' <- clarify e
  callClosure m e' es'
clarify (m, TermSigma _) = returnClosureType m -- Sigma is translated into Pi
clarify (m, TermSigmaIntro t es) = do
  t' <- reduceTermPlus t
  case t' of
    (mSig, TermSigma xts)
      | length xts == length es -> do
        tPi <- sigToPi mSig xts
        case tPi of
          (_, TermPi _ [zu, kp@(_, k, (_, TermPi _ yts _))] _) -- i.e. Sigma yts
            | length yts == length es -> do
              let xvs = map (\(_, x, _) -> toTermUpsilon x) yts
              let kv = toTermUpsilon k
              let bindArgsThen = \e -> (m, TermPiElim (m, TermPiIntro yts e) es)
              clarify $
                bindArgsThen (m, TermPiIntro [zu, kp] (m, TermPiElim kv xvs))
          _ -> throwError' "the type of sigma-intro is wrong"
    _ -> throwError' "the type of sigma-intro is wrong"
clarify (m, TermSigmaElim t xts e1 e2) = do
  clarify (m, TermPiElim e1 [t, (emptyMeta, TermPiIntro xts e2)])
clarify iter@(m, TermIter (_, x, t) mxts e) = do
  let (_, xs, ts) = unzip3 mxts
  let xts = zip xs ts
  forM_ ((x, t) : xts) $ uncurry insTypeEnv'
  e' <- clarify e
  fvs <- chainTermPlus iter
  retClosure' x fvs m mxts e'
clarify (m, TermConst x) = clarifyConst m x
clarify (_, TermConstDecl (_, x, t) e) = do
  _ <- clarify t
  insTypeEnv' x t
  clarify e
clarify (m, TermFloat16 l) = do
  return (m, CodeUpIntro (m, DataFloat16 l))
clarify (m, TermFloat32 l) = do
  return (m, CodeUpIntro (m, DataFloat32 l))
clarify (m, TermFloat64 l) = do
  return (m, CodeUpIntro (m, DataFloat64 l))
clarify (m, TermEnum _) = do
  v <- cartesianImmediate m
  return (m, CodeUpIntro v)
clarify (m, TermEnumIntro l) = do
  return (m, CodeUpIntro (m, DataEnumIntro l))
clarify (m, TermEnumElim (e, _) bs) = do
  let (cs, es) = unzip bs
  fvss <- mapM chainTermPlus' es
  let fvs = nubBy (\(_, x, _) (_, y, _) -> x == y) $ concat fvss
  es' <- mapM clarify es
  es'' <- mapM (retClosure Nothing fvs m []) es'
  es''' <- mapM (\cls -> callClosure m cls []) es''
  (yName, e', y) <- clarifyPlus e
  let varInfo = map (\(mx, x, _) -> (x, toDataUpsilon (x, mx))) fvs
  return $ bindLet [(yName, e')] (m, CodeEnumElim varInfo y (zip cs es'''))
clarify (m, TermArray {}) = do
  returnArrayType m
clarify (m, TermArrayIntro k es) = do
  retImmType <- returnCartesianImmediate
  -- arrayType = Sigma{k} [_ : IMMEDIATE, ..., _ : IMMEDIATE]
  name <- newNameWith' "array"
  let ts = map Left $ replicate (length es) retImmType
  arrayType <- cartesianSigma name m k ts
  (zs, es', xs) <- unzip3 <$> mapM clarifyPlus es
  return $
    bindLet (zip zs es') $
    ( m
    , CodeUpIntro $
      (m, DataSigmaIntro arrVoidPtr [arrayType, (m, DataSigmaIntro k xs)]))
clarify (m, TermArrayElim k mxts e1 e2) = do
  e1' <- clarify e1
  let (_, xs, ts) = unzip3 mxts
  let xts = zip xs ts
  forM_ xts $ uncurry insTypeEnv'
  (arrVarName, arrVar) <- newDataUpsilonWith "arr"
  (arrTypeVarName, arrTypeVar) <- newDataUpsilonWith "arr-type"
  let retArrTypeVar = (m, CodeUpIntro arrTypeVar)
  (arrInnerVarName, arrInnerVar) <- newDataUpsilonWith "arr-inner"
  retImmType <- returnCartesianImmediate
  ts' <- mapM clarify ts
  let xts' = zip xs ts'
  e2' <- clarify e2
  return $
    bindLet [(arrVarName, e1')] $
    ( m
    , CodeSigmaElim
        arrVoidPtr
        [(arrTypeVarName, retImmType), (arrInnerVarName, retArrTypeVar)]
        arrVar
        (m, CodeSigmaElim k xts' arrInnerVar e2'))
clarify (m, TermStruct ks) = do
  t <- cartesianStruct m ks
  return (m, CodeUpIntro t)
clarify (m, TermStructIntro eks) = do
  let (es, ks) = unzip eks
  (xs, es', vs) <- unzip3 <$> mapM clarifyPlus es
  return $
    bindLet (zip xs es') $ (m, CodeUpIntro (m, DataStructIntro (zip vs ks)))
clarify (m, TermStructElim xks e1 e2) = do
  e1' <- clarify e1
  let (_, xs, ks) = unzip3 xks
  ts <- mapM inferKind ks
  forM_ (zip xs ts) $ uncurry insTypeEnv'
  e2' <- clarify e2
  (structVarName, structVar) <- newDataUpsilonWith "struct"
  return $
    bindLet [(structVarName, e1')] (m, CodeStructElim (zip xs ks) structVar e2')

clarifyPlus :: TermPlus -> WithEnv (Identifier, CodePlus, DataPlus)
clarifyPlus e@(m, _) = do
  e' <- clarify e
  (varName, var) <- newDataUpsilonWith' "var" m
  return (varName, e', var)

clarifyConst :: Meta -> Identifier -> WithEnv CodePlus
clarifyConst m name@(I (x, _))
  | Just (lowType, op) <- asUnaryOpMaybe x = clarifyUnaryOp name op lowType m
clarifyConst m name@(I (x, _))
  | Just (lowType, op) <- asBinaryOpMaybe x = clarifyBinaryOp name op lowType m
clarifyConst m name@(I (x, _))
  | Just (sysCall, len) <- asSysCallMaybe x = clarifySysCall name sysCall len m
clarifyConst m (I (x, _))
  | Just _ <- asLowTypeMaybe x = clarify (m, TermEnum $ EnumTypeLabel "top")
clarifyConst m name
  | Just lowType <- asArrayAccessMaybe name = clarifyArrayAccess m name lowType
clarifyConst m (I ("file-descriptor", _)) = do
  i <- lookupConstNum "i64"
  clarify (m, TermConst (I ("i64", i)))
clarifyConst m (I ("stdin", _)) =
  clarify (m, TermEnumIntro (EnumValueIntS 64 0))
clarifyConst m (I ("stdout", _)) =
  clarify (m, TermEnumIntro (EnumValueIntS 64 1))
clarifyConst m (I ("stderr", _)) =
  clarify (m, TermEnumIntro (EnumValueIntS 64 2))
clarifyConst m name@(I (x, _)) = do
  cenv <- gets constantEnv
  case Map.lookup x cenv of
    Just _ -> return (m, CodeUpIntro (m, DataTheta name))
    Nothing -> throwError' $ "clarify.theta: " <> x
  -- if name `elem` cenv
  --   then return (m, CodeUpIntro (m, DataTheta name))
  --   else throwError' $ "clarify.theta: " <> name

clarifyUnaryOp :: Identifier -> UnaryOp -> LowType -> Meta -> WithEnv CodePlus
clarifyUnaryOp name op lowType m = do
  t <- lookupTypeEnv' name
  t' <- reduceTermPlus t
  case t' of
    (_, TermPi _ xts@[(mx, x, tx)] _) -> do
      let varX = toDataUpsilon (x, mx)
      zts <- complementaryChainOf xts
      -- p "one-time closure (unary)"
      retClosure
        (Just name)
        zts
        m
        [(mx, x, tx)]
        (m, CodeTheta (ThetaUnaryOp op lowType varX))
    _ -> throwError' $ "the arity of " <> asText name <> " is wrong"

clarifyBinaryOp :: Identifier -> BinaryOp -> LowType -> Meta -> WithEnv CodePlus
clarifyBinaryOp name op lowType m = do
  t <- lookupTypeEnv' name
  t' <- reduceTermPlus t
  case t' of
    (_, TermPi _ xts@[(mx, x, tx), (my, y, ty)] _) -> do
      let varX = toDataUpsilon (x, mx)
      let varY = toDataUpsilon (y, my)
      zts <- complementaryChainOf xts
      retClosure
        (Just name)
        zts
        m
        [(mx, x, tx), (my, y, ty)]
        (m, CodeTheta (ThetaBinaryOp op lowType varX varY))
    _ -> throwError' $ "the arity of " <> asText name <> " is wrong"

clarifyArrayAccess :: Meta -> Identifier -> LowType -> WithEnv CodePlus
clarifyArrayAccess m name lowType = do
  arrayAccessType <- lookupTypeEnv' name
  arrayAccessType' <- reduceTermPlus arrayAccessType
  case arrayAccessType' of
    (_, TermPi _ xts cod)
      | length xts == 3 -> do
        (xs, ds, headerList) <-
          computeHeader m xts [ArgUnused, ArgArray, ArgImmediate]
        case ds of
          [arr, index] -> do
            zts <- complementaryChainOf xts
            callThenReturn <- toArrayAccessTail m lowType cod arr index xs
            let body = iterativeApp headerList callThenReturn
            retClosure (Just name) zts m xts body
          _ -> throwError' $ "the type of array-access is wrong"
    _ -> throwError' $ "the type of array-access is wrong"

clarifySysCall ::
     Identifier -- the name of theta
  -> SysCall -- the kind of system call
  -> [Arg] -- the length of the arguments of the theta
  -> Meta -- the meta of the theta
  -> WithEnv CodePlus
clarifySysCall name sysCall args m = do
  sysCallType <- lookupTypeEnv' name
  sysCallType' <- reduceTermPlus sysCallType
  case sysCallType' of
    (_, TermPi _ xts cod)
      | length xts == length args -> do
        zts <- complementaryChainOf xts
        (xs, ds, headerList) <- computeHeader m xts args
        callThenReturn <- toSysCallTail m cod sysCall ds xs
        let body = iterativeApp headerList callThenReturn
        os <- getOS
        case (sysCall, os) of
          (SysCallFork, OSDarwin) -> do
            name' <- newNameWith' "fork"
            retClosure (Just name') zts m xts body
          _ -> retClosure (Just name) zts m xts body
    _ -> throwError' $ "the type of " <> asText name <> " is wrong"

iterativeApp :: [a -> a] -> a -> a
iterativeApp [] x = x
iterativeApp (f:fs) x = f (iterativeApp fs x)

complementaryChainOf ::
     [(Meta, Identifier, TermPlus)] -> WithEnv [(Meta, Identifier, TermPlus)]
complementaryChainOf xts = do
  zts <- chainTermPlus'' xts []
  return $ nubBy (\(_, x, _) (_, y, _) -> x == y) zts

toVar :: Identifier -> DataPlus
toVar x = (emptyMeta, DataUpsilon x)

clarifyBinder ::
     [(Meta, Identifier, TermPlus)] -> WithEnv [(Meta, Identifier, CodePlus)]
clarifyBinder [] = return []
clarifyBinder ((m, x, t):xts) = do
  t' <- clarify t
  xts' <- clarifyBinder xts
  return $ (m, x, t') : xts'

retClosure ::
     Maybe Identifier -- the name of newly created closure
  -> [(Meta, Identifier, TermPlus)] -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  -> Meta -- meta of lambda
  -> [(Meta, Identifier, TermPlus)] -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  -> CodePlus -- the `e` in `lam (x1, ..., xn). e`
  -> WithEnv CodePlus
retClosure mName fvs m xts e = do
  cls <- makeClosure' mName fvs m xts e
  return (m, CodeUpIntro cls)

retClosure' ::
     Identifier -- the name of newly created closure
  -> [(Meta, Identifier, TermPlus)] -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  -> Meta -- meta of lambda
  -> [(Meta, Identifier, TermPlus)] -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  -> CodePlus -- the `e` in `lam (x1, ..., xn). e`
  -> WithEnv CodePlus
retClosure' x fvs m xts e = do
  cls <- makeClosure' (Just x) fvs m xts e
  knot x cls
  return (m, CodeUpIntro cls)

makeClosure' ::
     Maybe Identifier -- the name of newly created closure
  -> [(Meta, Identifier, TermPlus)] -- list of free variables in `lam (x1, ..., xn). e` (this must be a closed chain)
  -> Meta -- meta of lambda
  -> [(Meta, Identifier, TermPlus)] -- the `(x1 : A1, ..., xn : An)` in `lam (x1 : A1, ..., xn : An). e`
  -> CodePlus -- the `e` in `lam (x1, ..., xn). e`
  -> WithEnv DataPlus
makeClosure' mName fvs m xts e = do
  fvs' <- clarifyBinder fvs
  xts' <- clarifyBinder xts
  makeClosure mName fvs' m xts' e

knot :: Identifier -> DataPlus -> WithEnv ()
knot z cls = do
  cenv <- gets codeEnv
  case pop z cenv of
    Nothing -> throwError' "knot"
    Just ((Definition _ args body), cenv') -> do
      let body' = substCodePlus [(z, cls)] body
      let def' = Definition (IsFixed True) args body'
      let cenv'' = Map.insert z def' cenv'
      modify (\env -> env {codeEnv = cenv''})

-- lookup and remove the matching element from the given assoc list
-- (hashmapだったらpopする必要あらず)
pop ::
     Identifier
  -> Map.HashMap Identifier b
  -> Maybe (b, Map.HashMap Identifier b)
pop x mp = do
  v <- Map.lookup x mp
  return (v, Map.delete x mp)

-- array-access-u8 ~> Just u8
-- array-access-i12341234 ~> Just i12341234
asArrayAccessMaybe :: Identifier -> Maybe LowType
asArrayAccessMaybe (I (name, _))
  | ["array-access", typeStr] <- sepAtLast '-' name
  , Just lowType <- asLowTypeMaybe typeStr = Just lowType
asArrayAccessMaybe _ = Nothing

sepAtLast :: Char -> T.Text -> [T.Text]
sepAtLast c s =
  case wordsBy c s of
    [] -> []
    [s'] -> [s']
    ss -> [T.intercalate (T.singleton c) (init ss), last ss]

asSysCallMaybe :: T.Text -> Maybe (SysCall, [Arg])
asSysCallMaybe "write" =
  Just (SysCallWrite, [ArgUnused, ArgImmediate, ArgArray, ArgImmediate])
asSysCallMaybe "read" =
  Just (SysCallRead, [ArgUnused, ArgImmediate, ArgArray, ArgImmediate])
asSysCallMaybe "exit" = Just (SysCallExit, [ArgImmediate])
asSysCallMaybe "open" =
  Just (SysCallOpen, [ArgUnused, ArgArray, ArgImmediate, ArgImmediate])
asSysCallMaybe "close" = Just (SysCallClose, [ArgImmediate])
asSysCallMaybe "fork" = Just (SysCallFork, [])
asSysCallMaybe "socket" =
  Just (SysCallSocket, [ArgImmediate, ArgImmediate, ArgImmediate])
asSysCallMaybe "listen" = Just (SysCallListen, [ArgImmediate, ArgImmediate])
asSysCallMaybe "wait4" =
  Just (SysCallWait4, [ArgImmediate, ArgArray, ArgImmediate, ArgStruct])
asSysCallMaybe "bind" =
  Just (SysCallBind, [ArgImmediate, ArgStruct, ArgImmediate])
asSysCallMaybe "accept" =
  Just (SysCallAccept, [ArgImmediate, ArgStruct, ArgArray])
asSysCallMaybe "connect" =
  Just (SysCallConnect, [ArgImmediate, ArgStruct, ArgImmediate])
asSysCallMaybe _ = Nothing

data Arg
  = ArgImmediate
  | ArgArray
  | ArgStruct
  | ArgUnused
  deriving (Show)

toHeaderInfo ::
     Meta
  -> Identifier -- argument
  -> TermPlus -- the type of argument
  -> Arg -- the way of use of argument (specifically)
  -> WithEnv ([Identifier], [DataPlus], CodePlus -> CodePlus) -- ([borrow], arg-to-syscall, ADD_HEADER_TO_CONTINUATION)
toHeaderInfo _ x _ ArgImmediate = return ([], [toVar x], id)
toHeaderInfo _ _ _ ArgUnused = return ([], [], id)
toHeaderInfo m x t ArgStruct = do
  (structVarName, structVar) <- newDataUpsilonWith "struct"
  insTypeEnv' structVarName t
  return
    ( [structVarName]
    , [structVar]
    , \cont -> (m, CodeUpElim structVarName (m, CodeUpIntro (toVar x)) cont))
toHeaderInfo m x t ArgArray = do
  arrayVarName <- newNameWith' "array"
  insTypeEnv' arrayVarName t
  (arrayTypeName, arrayType) <- newDataUpsilonWith "array-type"
  (arrayInnerName, arrayInner) <- newDataUpsilonWith "array-inner"
  (arrayInnerTmpName, arrayInnerTmp) <- newDataUpsilonWith "array-tmp"
  retImmType <- returnCartesianImmediate
  return
    ( [arrayVarName]
    , [arrayInnerTmp]
    , \cont ->
        ( m
        , CodeSigmaElim
            arrVoidPtr
            [ (arrayTypeName, retImmType)
            , (arrayInnerName, (m, CodeUpIntro arrayType))
            ]
            (toVar x)
            ( m
            , CodeUpElim
                arrayInnerTmpName
                (m, CodeUpIntroNoReduce arrayInner)
                ( m
                , CodeUpElim
                    arrayVarName
                    ( m
                    , CodeUpIntro
                        ( m
                        , DataSigmaIntro arrVoidPtr [arrayType, arrayInnerTmp]))
                    cont -- contの中でarrayInnerTmpを使用することで配列を利用
                 ))))

computeHeader ::
     Meta
  -> [(Meta, Identifier, TermPlus)]
  -> [Arg]
  -> WithEnv ([Identifier], [DataPlus], [CodePlus -> CodePlus])
computeHeader m xts argInfoList = do
  let xtas = zip xts argInfoList
  (xss, dss, headerList) <-
    unzip3 <$> mapM (\((_, x, t), a) -> toHeaderInfo m x t a) xtas
  return (concat xss, concat dss, headerList)

toSysCallTail ::
     Meta
  -> TermPlus -- cod type
  -> SysCall -- read, write, open, etc
  -> [DataPlus] -- args of syscall
  -> [Identifier] -- borrowed variables
  -> WithEnv CodePlus
toSysCallTail m cod syscall args xs = do
  resultVarName <- newNameWith' "result"
  result <- retWithBorrowedVars m cod xs resultVarName
  os <- getOS
  case (syscall, os) of
    (SysCallFork, OSDarwin)
      -- i <- lookupConstNum' "fork"
     -> do
      return
        ( m
        , CodeUpElim
            resultVarName
            (m, CodePiElimDownElim (m, DataTheta (I ("fork", 0))) args)
            result)
    _ ->
      return
        ( m
        , CodeUpElim
            resultVarName
            (m, CodeTheta (ThetaSysCall syscall args))
            result)

toArrayAccessTail ::
     Meta
  -> LowType
  -> TermPlus -- cod type
  -> DataPlus -- array (inner)
  -> DataPlus -- index
  -> [Identifier] -- borrowed variables
  -> WithEnv CodePlus
toArrayAccessTail m lowType cod arr index xs = do
  resultVarName <- newNameWith' "result"
  result <- retWithBorrowedVars m cod xs resultVarName
  return
    ( m
    , CodeUpElim
        resultVarName
        (m, CodeTheta (ThetaArrayAccess lowType arr index))
        result)

retWithBorrowedVars ::
     Meta -> TermPlus -> [Identifier] -> Identifier -> WithEnv CodePlus
retWithBorrowedVars m _ [] resultVarName =
  return (m, CodeUpIntro (m, DataUpsilon resultVarName))
retWithBorrowedVars m cod xs resultVarName
  | (mSig, TermSigma yts) <- cod
  , length yts >= 1 = do
    tPi <- sigToPi mSig yts
    case tPi of
      (_, TermPi _ [c, (mFun, funName, funType@(_, TermPi _ xts _))] _) -> do
        let (_, _, resultType) = last xts
        let vs = map (\x -> (m, TermUpsilon x)) $ xs ++ [resultVarName]
        insTypeEnv' resultVarName resultType
        clarify
          ( m
          , TermPiIntro
              [c, (mFun, funName, funType)]
              (m, TermPiElim (m, TermUpsilon funName) vs))
      _ -> throwError' "retWithBorrowedVars (sig)"
  | otherwise = throwError' "retWithBorrowedVars"

inferKind :: ArrayKind -> WithEnv TermPlus
inferKind (ArrayKindIntS i) = return (emptyMeta, TermEnum (EnumTypeIntS i))
inferKind (ArrayKindIntU i) = return (emptyMeta, TermEnum (EnumTypeIntU i))
inferKind (ArrayKindFloat size) = do
  let constName = "f" <> T.pack (show (sizeAsInt size))
  i <- lookupConstNum' constName
  return (emptyMeta, TermConst (I (constName, i)))
  -- (emptyMeta, TermConst $ "f" <> T.pack (show (sizeAsInt size)))
inferKind _ = error "inferKind for void-pointer"

sigToPi :: Meta -> [Data.Term.IdentifierPlus] -> WithEnv TermPlus
sigToPi m xts = do
  z <- newNameWith' "sigma"
  let zv = toTermUpsilon z
  k <- newNameWith' "sig"
  -- Sigma [x1 : A1, ..., xn : An] = Pi (z : Type, _ : Pi [x1 : A1, ..., xn : An]. z). z
  l <- newCount
  -- don't care the level since they're discarded immediately
  -- (i.e. this translated term is not used as an argument of `weaken`)
  return
    (m, TermPi [] [(m, z, (m, TermTau l)), (m, k, (m, TermPi [] xts zv))] zv)
