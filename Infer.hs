{-# LANGUAGE DeriveGeneric, DeriveFunctor, DeriveFoldable, DeriveTraversable #-}

module Infer where

import Types
--import Pretty

-- TODO:
-- 
-- * support 'this' by assuming equivalences:
--   - f(..) == f.bind(window, ..)
--   - o.f(..) == f.bind(o, ..)
--
-- * support return; ( == return undefined;)
-- 
-- * support new (e.g. add body Constructor ... that's like a func
-- 
-- * check zips for missing errors (zip of lists of different sizes)
--
-- * don't allow assigning to function args? (lint issue only)

import Data.List(intersperse)
import Data.Maybe(fromJust, isJust, isNothing) --, fromMaybe)
import Data.Either(isLeft, lefts)
import Text.PrettyPrint.GenericPretty(Generic)
import Control.Monad.State(State, runState, forM, get, put)
import Data.Traversable(Traversable(..))
import Data.Foldable(Foldable(..))
import qualified Data.Map.Lazy as Map
import Prelude hiding (foldr, mapM)
import Control.Monad()

fromRight :: Show a => Either a b -> b
fromRight (Right x) = x
fromRight (Left x) = error $ "expected: Right _, got: Left " ++ (show x)


getVarType :: VarScope -> String -> Maybe JSType
getVarType Global _ = Nothing
getVarType scope name = case lookup name (vars scope) of
                       Nothing -> getVarType (parent scope) name
                       Just t -> Just t

intrVars :: [String] -> State Scope VarScope
intrVars names = do
  scope <- get
  let varScope' = varScope scope
  vs <- forM names $ \name -> do
          varType' <-  allocTVar
          return (name, varType')

  return VarScope { parent = varScope', vars = vs }

updateVarScope :: VarScope -> State Scope ()
updateVarScope v = do
  scope <- get
  put $ scope { varScope = v }

allocTVar' :: TypeScope -> (JSType, TypeScope)
allocTVar' tscope = (JSTVar allocedNum, updatedScope)
    where updatedScope = tscope { maxNum = allocedNum }
          allocedNum = (maxNum tscope) + 1


allocTVar :: State Scope JSType
allocTVar = do
  scope <- get
  let typeScope' = typeScope scope
      (varType', typeScope'') = allocTVar' typeScope'
  put $ scope { typeScope = typeScope'' }
  return varType'


emptyTypeScope :: TypeScope
emptyTypeScope = TypeScope Map.empty 0

emptyScope :: Scope
emptyScope = Scope { typeScope = emptyTypeScope, funcScope = Nothing, varScope = Global }

-- rightExpr :: Scope -> Body (Expr (Scope, (Either a b))) -> b -> Expr (Scope, (Either a b))
-- rightExpr scope body x = Expr body (scope, Right x)

exprData :: Expr t -> t
exprData (Expr _ t) = t

exprBody :: Expr t -> Body (Expr t)
exprBody (Expr b _) = b


getFuncReturnType :: State Scope (Maybe JSType)
getFuncReturnType = do
  scope <- get
  case funcScope scope of
    Nothing -> return Nothing
    Just funcScope' -> return . Just $ returnType funcScope'

setFuncReturnType :: JSType -> State Scope (Maybe TypeError)
setFuncReturnType retType = do
  scope <- get
  case funcScope scope of
    Nothing -> return . Just $ TypeError "return outside function scope"
    Just funcScope' -> do
      put $ scope { funcScope = Just $ funcScope' { returnType = retType } }
      return Nothing

-- declVar :: String -> State Scope (Maybe JSType)
-- declVar name = do
--   scope <- get
--   case funcScope scope of
--     Nothing -> return . Just $ TypeError "

isErrExpr :: InferredExpr -> Bool
isErrExpr (Expr _ (Left _)) = True
isErrExpr _ = False

getExprResult :: InferredExpr -> Either TypeError JSType
getExprResult (Expr _ result) = result

getExprType :: InferredExpr -> Maybe JSType
getExprType (Expr _ (Right t)) = Just t
getExprType _ = Nothing

getExprError :: InferredExpr -> Maybe TypeError
getExprError (Expr _ (Left e)) = Just e
getExprError _ = Nothing

-- coerceTypes :: JSType -> JSType -> State Scope (Either TypeError JSType)
-- coerceTypes t u = coerceTypes' (trace ("bla:" ++ (concat $ intersperse " -- " $ map show [t, u])) t) u 

coerceTypes :: JSType -> JSType -> State Scope (Either TypeError JSType)
coerceTypes t u = do
  scope <- get
  let typeScope' = typeScope scope
  let tsubst = tVars typeScope'
  case unify tsubst (toType $ t) (toType $ u) of
    Nothing -> return . Left . TypeError $ "Failed unifying types: " ++ (show t) ++ " and " ++ (show u)
    Just x -> do
      let tsubst' = x
      let scope' = scope { typeScope = typeScope' { tVars = tsubst' } }
      put scope'
      return . Right . fromType $ substituteType tsubst' (toType t)

resolveType :: JSType -> State Scope JSType
resolveType t = do
  scope <- get
  let typeScope' = typeScope scope
  let tsubst = tVars typeScope'
  return . fromType $ substituteType tsubst (toType t)

inferStatement ::  Statement (Expr a) -> State Scope InferredStatement
inferStatement st = do
  let ok st' = return $ Right st'
      err st' e = return $ Left (e, st')
  case st of
    Empty -> ok Empty

    Expression expr ->
        do inferredExpr <- inferType expr
           let newSt = Expression inferredExpr
           case getExprResult inferredExpr of
             Left e -> err newSt e
             Right _ -> ok newSt 
            
    Block xs -> 
        do results <- mapM inferStatement xs
           let newSt = Block $ map getInferredStatement results
           case lefts results of 
             [] -> ok newSt
             _ -> err newSt $ TypeError "error in statement block"

    IfThenElse expr stThen stElse ->
        do inferredExpr <- inferType expr
           stThen' <- inferStatement stThen
           stElse' <- inferStatement stElse
           let stThen'' = getInferredStatement stThen'
               stElse'' = getInferredStatement stElse'
               newSt = IfThenElse inferredExpr stThen'' stElse''
           case getExprResult inferredExpr of
             Left e -> err newSt e
             Right t -> 
                 do coercedPredType <- coerceTypes t JSBoolean
                    case (coercedPredType, stThen' , stElse') of
                      (Right _, Right _, Right _) -> ok newSt
                      _ -> err newSt $ TypeError "error in if-then-else"

    Return Nothing -> 
        do returnT <- getFuncReturnType
           case returnT of
             Nothing -> trySetReturnType JSUndefined
             Just returnT' -> 
                 do t <- coerceTypes returnT' JSUndefined
                    case t of
                      Left e -> err newSt e
                      Right t' -> trySetReturnType t'

        where newSt = Return Nothing
              trySetReturnType t = do
               returnT' <- setFuncReturnType t
               case returnT' of
                 Nothing -> ok newSt
                 Just e -> err newSt e


    Return (Just expr) -> 
        do inferredExpr <- inferReturnType expr
           let newSt = Return $ Just inferredExpr
           case getExprResult inferredExpr of
             Left e -> err newSt e
             Right _ -> ok newSt

    While expr stWhile ->
        do inferredExpr <- inferType expr
           inferredStWhile <- inferStatement stWhile
           let inferredStWhile' = getInferredStatement inferredStWhile
               newSt = While inferredExpr inferredStWhile'
           case getExprResult inferredExpr of
             Left e -> err newSt e
             Right t -> 
                 do coercedPredType <- coerceTypes t JSBoolean
                    case (coercedPredType, inferredStWhile) of 
                      (Right _, Right _) -> ok newSt
                      _ -> err newSt $ TypeError "error in while statment"

    VarDecl name ->
        do updatedVarScope <- intrVars [name]
           scope <- get
           put $ scope { varScope = updatedVarScope }
           ok $ VarDecl name

type InferredResult = Either TypeError JSType
type InferredStatement = Either (TypeError, Statement InferredExpr) (Statement InferredExpr)
type InferredExpr = Expr InferredResult

getInferredStatement :: Either (a, b) b -> b
getInferredStatement (Left (_, x)) = x
getInferredStatement (Right x) = x



inferType ::  Expr a -> State Scope InferredExpr
inferType e = do
  inferredExpr <- inferType' e
  case inferredExpr of
    Expr _ (Left _) -> return inferredExpr
    Expr a (Right t) ->
      do t' <- resolveType t
         return $ Expr a (Right t')
  

inferType' ::   Expr a -> State Scope InferredExpr
inferType' (Expr body _) = do
  case body of
    LitArray exprs -> inferArrayType exprs
    LitBoolean x -> simpleType JSBoolean $ LitBoolean x
    LitFunc name argNames exprs -> inferFuncType name argNames exprs
    LitNumber x -> simpleType JSNumber $ LitNumber x
    LitObject props -> inferObjectType props
    LitRegex x -> simpleType JSRegex $ LitRegex x
    LitString x -> simpleType JSString $ LitString x
    Var name -> inferVarType name
    Call callee args -> inferCallType callee args
    Assign dest src -> inferAssignType dest src
    Property expr name -> inferPropertyType expr name
    Index arrExpr indexExpr -> inferIndexType arrExpr indexExpr
  where simpleType t body' = return $ simply t body'

        
simply :: t -> Body (Expr (Either a t)) -> Expr (Either a t)
simply t b = Expr b (Right t)

makeError' :: Body (Expr (Either a b)) -> a -> Expr (Either a b)
makeError' b typeError = Expr b (Left typeError)

makeError :: Body (Expr (Either TypeError b)) -> String -> Expr (Either TypeError b)
makeError b str = makeError' b $ TypeError str

inferIndexType :: Expr a -> Expr a  -> State Scope InferredExpr
inferIndexType arrExpr indexExpr = do
  inferredArrExpr <- inferType arrExpr
  inferredIndexExpr <- inferType indexExpr
  let newBody = Index inferredArrExpr inferredIndexExpr
  if any isNothing $ map getExprType [inferredArrExpr, inferredIndexExpr]
  then return . makeError newBody $ "couldn't infer index target or value"
  else do
    let arrType = getExprType $ inferredArrExpr
        indexType = getExprType $ inferredIndexExpr
        
    case (arrType, indexType) of
      (Just (JSArray elemType), Just JSNumber) -> return $ simply elemType newBody
      _ -> return . makeError newBody $ "Left-hand side of index is not an array or right-hand side is not a number"
    

inferAssignType :: Expr a -> Expr a -> State Scope InferredExpr
inferAssignType dest src = do
  inferredDest <- inferType dest
  inferredSrc <- inferType src
  let newBody = Assign inferredDest inferredSrc
  if any isNothing $ map getExprType [inferredSrc, inferredDest]
  then return . makeError newBody $ "couldn't infer left or right of assign statement"
  else do 
    let destType = fromJust . getExprType $ inferredDest
        srcType = fromJust . getExprType $ inferredSrc
        infer' = do
          varType <- coerceTypes destType srcType
          case varType of 
            Left err -> return . makeError' newBody $ err
            Right varType' -> return $ simply varType' newBody
    case exprBody inferredDest of
      Var _ -> infer'
      Property _ _ -> infer' -- TODO update object type?
      _ -> return . makeError newBody $ "Left-hand side of assignment is not an lvalue"

inferPropertyType :: Expr a -> String -> State Scope InferredExpr
inferPropertyType objExpr propName =
    do inferredObjExpr <- inferType objExpr
       let newBody = Property inferredObjExpr propName
           objType = getExprType inferredObjExpr
       case objType of
         Nothing -> return . makeError newBody $ "failed inferring object type"
         Just objType' ->
           do case getObjPropertyType objType' propName of
                Nothing -> return . makeError newBody $ ("object type has no property named '" ++ propName ++ "'")
                Just propType' -> do
                  return $ simply propType' newBody

inferCallType :: Expr a -> [Expr a] -> State Scope InferredExpr
inferCallType callee args = do
  inferredCallee <- inferType callee
  inferredArgs <- mapM inferType args
  let newBody = Call inferredCallee inferredArgs
  case getExprType inferredCallee of
    Nothing -> return . makeError newBody $ "couldn't infer callee in call expression"
    Just (JSFunc argsT' res') -> do
      let maybeArgsT = map getExprType inferredArgs
      if any isNothing maybeArgsT
      then return . makeError newBody $ "couldn't infer arg types in call expression"
      else do
        let argsT = map fromJust maybeArgsT
        unifiedArgTypes <- mapM (uncurry coerceTypes) $ zip argsT argsT'
        if any isLeft unifiedArgTypes
        then return . makeError newBody $ "actual argument types do not match callee argument types:" 
                 ++ (concat $ intersperse "\n" (map show $ lefts unifiedArgTypes))
        else return $ simply res' newBody
    Just _ -> return . makeError newBody $ "callee is not a function"
  
inferVarType :: String -> State Scope InferredExpr
inferVarType name = do
  scope <- get
  let varType = getVarType (varScope scope) name
  case varType of 
    Nothing -> return . makeError (Var name) $ "undeclared variable: " ++ name
    Just varType' -> return . simply varType' $ Var name

inferArrayType :: [Expr a] -> State Scope InferredExpr
inferArrayType exprs = 
    do inferredExprs <- forM exprs inferType
       let newBody = LitArray inferredExprs
       if any isErrExpr inferredExprs
       then return $ makeError newBody "array elements are badly typed"
       else case map (fromJust . getExprType) inferredExprs of
              [] -> do elemType <- allocTVar
                       return . simply (JSArray elemType) $ LitArray inferredExprs
              (x:xs) -> if any (/= x) xs
                        then return $ makeError (LitArray inferredExprs) "inconsistent array element types"
                        else return . simply (JSArray x) $ LitArray inferredExprs

inferFuncType :: Maybe String -> [String] -> [Statement (Expr a)] -> State Scope InferredExpr
inferFuncType name argNames exprs =
    do returnType' <- allocTVar
       let funcScope' = FuncScope { returnType = returnType' }
       funcVarType <- case name of -- TODO de-uglify
         Just x -> do 
           funcNameScope <- intrVars [x]
           updateVarScope funcNameScope
           return . Just . snd . head $ vars funcNameScope
         Nothing -> return Nothing
       argScope <- intrVars argNames
       scope <- get
       let (inferredStatments', Scope typeScope'' _ funcScope'') = 
               flip runState (scope { funcScope = Just funcScope', varScope = argScope }) 
                    $ forM exprs inferStatement
           inferredStatments = (map getInferredStatement inferredStatments')
       put $ scope { typeScope = typeScope'' }
       let newBody = LitFunc name argNames inferredStatments
       if any isLeft inferredStatments'
       then return $ makeError newBody "Error in function body"
       else do
         let funcType = JSFunc (map snd $ vars argScope) (returnType . fromJust $ funcScope'')
         unifiedFuncType' <- case funcVarType of
           Nothing -> return $ Right funcType
           Just x -> coerceTypes x funcType
         case unifiedFuncType' of
           Left e -> return $ makeError newBody "Error inferring function type"
           Right t -> return $ simply t newBody

inferReturnType ::  Expr a -> State Scope InferredExpr
inferReturnType expr =
    do (Expr newBody res) <- inferType expr
       case res of 
         Left _ -> return $ makeError newBody "Error in return expression"
         Right retType -> 
             do curReturnType <- getFuncReturnType
                if isJust curReturnType
                then do
                  maybeT <- coerceTypes retType $ fromJust curReturnType
                  case maybeT of
                    Left e -> return $ makeError' newBody e
                    Right t -> setRetType t
                else setRetType retType
             where setRetType retType' = 
                       do setFailed <- setFuncReturnType retType'
                          case setFailed of
                            Nothing -> return . simply retType' $ newBody
                            Just _ -> return $ makeError newBody "Error in return expression"
 
inferObjectType :: [(String, Expr a)] -> State Scope InferredExpr
inferObjectType props =
    do let propNames = map fst props
       let propExprs = map snd props
       inferredProps <- mapM inferType propExprs
       let newBody = LitObject $ zip propNames inferredProps
       if any isErrExpr inferredProps
       then return $ makeError newBody "object properties are badly typed"
       else return 
                . simply (JSObject 
                                  $ zip propNames 
                                  $ map (fromJust . getExprType) inferredProps) 
                      $ newBody

