module Reduce.Code where
-- reduceWeakCode :: WeakCodePlus -> WithEnv WeakCodePlus
-- reduceWeakCode (WeakCodePiElimDownElim v vs) =
--   case v of
--     PosConst x -> do
--       penv <- gets polEnv
--       case lookup x penv of
--         Just (args, body)
--           | length args == length vs ->
--             reduceWeakCode $ substWeakCode (zip args vs) body
--         _ -> return $ WeakCodePiElimDownElim v vs
--     _ -> return $ WeakCodePiElimDownElim v vs
-- reduceWeakCode (WeakCodeSigmaElim xs v body) =
--   case v of
--     PosSigmaIntro vs
--       | length xs == length vs ->
--         reduceWeakCode $ substWeakCode (zip xs vs) body
--     _ -> return $ WeakCodeSigmaElim xs v body
-- reduceWeakCode (WeakCodeEpsilonElim v branchList) =
--   case v of
--     PosEpsilonIntro l _ ->
--       case lookup (CaseLiteral l) branchList of
--         Just body -> reduceWeakCode body
--         Nothing ->
--           case lookup CaseDefault branchList of
--             Just body -> reduceWeakCode body
--             Nothing ->
--               lift $
--               throwE $
--               "the index " ++ show l ++ " is not included in branchList"
--     _ -> return $ WeakCodeEpsilonElim v branchList
-- reduceWeakCode (WeakCodeUpElim x e1 e2) = do
--   e1' <- reduceWeakCode e1
--   case e1' of
--     WeakCodeUpIntro v -> reduceWeakCode $ substWeakCode [(x, v)] e2
--     _                 -> return $ WeakCodeUpElim x e1' e2
-- reduceWeakCode (WeakCodeConstElim (ConstantLabel x) vs) = do
--   penv <- gets polEnv
--   case lookup x penv of
--     Just (args, body)
--       | length args == length vs ->
--         reduceWeakCode $ substWeakCode (zip args vs) body
--     _ -> return $ WeakCodeConstElim (ConstantLabel x) vs
-- reduceWeakCode (WeakCodeConstElim c vs) = do
--   let xs = takeIntegerList vs
--   let t = LowTypeSignedInt 64 -- for now
--   case (c, xs) of
--     (ConstantArith _ ArithAdd, Just [x, y]) ->
--       return $ WeakCodeUpIntro (PosEpsilonIntro (LiteralInteger (x + y)) t)
--     (ConstantArith _ ArithSub, Just [x, y]) ->
--       return $ WeakCodeUpIntro (PosEpsilonIntro (LiteralInteger (x - y)) t)
--     (ConstantArith _ ArithMul, Just [x, y]) ->
--       return $ WeakCodeUpIntro (PosEpsilonIntro (LiteralInteger (x * y)) t)
--     (ConstantArith _ ArithDiv, Just [x, y]) ->
--       return $ WeakCodeUpIntro (PosEpsilonIntro (LiteralInteger (x `div` y)) t)
--     _ -> return $ WeakCodeConstElim c vs
-- reduceWeakCode e = return e
-- takeIntegerList :: [WeakData] -> Maybe [Int]
-- takeIntegerList [] = Just []
-- takeIntegerList (WeakDataEpsilonIntro (LiteralInteger i) _:rest) = do
--   is <- takeIntegerList rest
--   return (i : is)
-- takeIntegerList _ = Nothing