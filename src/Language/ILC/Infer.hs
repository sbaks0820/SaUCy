{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE TypeSynonymInstances       #-}
{-# LANGUAGE TupleSections              #-}

--------------------------------------------------------------------------------
-- |
-- Module      :  Language.ILC.Infer
-- Copyright   :  (C) 2018 Kevin Liao
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  Kevin Liao (kliao6@illinois.edu)
-- Stability   :  experimental
--
-- Damas-Milner type inference for ILC programs.
--
--------------------------------------------------------------------------------

module Language.ILC.Infer (
    inferExpr
  , inferTop
  , closeOver
  ) where

import Control.Monad.Except
import Control.Monad.Identity
import Control.Monad.Reader
import Control.Monad.State
import Data.List (nub, (\\))
import qualified Data.Map as Map
import qualified Data.Set as Set
import Development.Placeholders
import Debug.Trace

import Language.ILC.Syntax
import Language.ILC.Type
import Language.ILC.TypeError

-- | Inference monad
type Infer a = (ReaderT
                  TypeEnv
                  (StateT
                  InferState
                  (Except
                    TypeError))
                  a)

-- | Inference state
newtype InferState = InferState { count :: Int }

-- | Initial inference state
initInfer :: InferState
initInfer = InferState { count = 0 }

type Constraint = (Type, Type)

type Unifier = (Subst, [Constraint])
      
-- | Constraint solver monad
type Solve a = ExceptT TypeError Identity a

newtype Subst = Subst (Map.Map TVar Type)
  deriving (Eq, Ord, Show, Monoid)

class Substitutable a where
  apply :: Subst -> a -> a
  ftv   :: a -> Set.Set TVar

instance Substitutable Type where
  apply s (IType t) = IType (apply s t)
  apply s (AType t) = AType (apply s t)

  ftv (IType t) = ftv t
  ftv (AType t) = ftv t  

instance Substitutable IType where
  apply (Subst s) t@(IVar a) = strip $ Map.findWithDefault (IType t) a s
    where
      strip (IType x) = x
  apply _ (ICon a) = ICon a
  apply s (IProd ts) = IProd (apply s ts)
  apply s (IArr t1 t2) = IArr (apply s t1) (apply s t2)
  apply s (IList t) = IList (apply s t)
  apply s (IWrChan t) = IWrChan (apply s t)
  apply s (ICust t) = ICust (apply s t)
  apply s (ISend t) = ISend (apply s t)  

  ftv (IVar a) = Set.singleton a
  ftv ICon{} = Set.empty
  ftv (IProd ts) = ftv ts  
  ftv (IArr t1 t2) = ftv t1 `Set.union` ftv t2
  ftv (IList t) = ftv t
  ftv (IWrChan t) = ftv t
  ftv (ICust t) = ftv t
  ftv (ISend t) = ftv t  

instance Substitutable AType where
  apply (Subst s) t@(AVar a) = strip $ Map.findWithDefault (AType t) a s
    where
      strip (AType x) = x
  apply s (ARdChan t) = ARdChan (apply s t)  
  apply s (AProd ts) = AProd (apply s ts)
  apply s (ABang t) = ABang (apply s t)

  ftv (AVar a) = Set.singleton a
  ftv (ARdChan t) = ftv t  
  ftv (AProd ts) = ftv ts
  ftv (ABang t) = ftv t    

instance Substitutable SType where
  apply (Subst s) t@(SVar a) = strip $ Map.findWithDefault (IType (ISend t)) a s
    where
      strip (IType (ISend x)) = x
  apply s (SProd ts) = SProd (apply s ts)
  apply _ (SCon a) = SCon a  

  ftv (SVar a) = Set.singleton a
  ftv (SProd ts) = ftv ts
  ftv SCon{} = Set.empty  

instance Substitutable Scheme where
  apply (Subst s) (Forall as t) = Forall as $ apply s' t
    where s' = Subst $ foldr Map.delete s as
  ftv (Forall as t) = ftv t `Set.difference` Set.fromList as

instance Substitutable Constraint where
  apply s (t1, t2) = (apply s t1, apply s t2)
  
  ftv (t1, t2) = ftv t1 `Set.union` ftv t2

instance Substitutable a => Substitutable [a] where
  apply = fmap . apply

  ftv = foldr (Set.union . ftv) Set.empty

instance Substitutable TypeEnv where
  apply s (TypeEnv env) = TypeEnv $ Map.map (apply s) env
  ftv (TypeEnv env) = ftv $ Map.elems env

-------------------------------------------------------------------------------
-- Inference
-------------------------------------------------------------------------------

-- | Run the inference monad
runInfer :: TypeEnv
         -> Infer (Type, [Constraint], TypeEnv)
         -> Either TypeError (Type, [Constraint], TypeEnv)
runInfer env m = runExcept $ evalStateT (runReaderT m env) initInfer

-- | Solve for type of top-level expression in a given environment
inferExpr :: TypeEnv -> Expr -> Either TypeError Scheme
inferExpr env ex = case runInfer env (infer ex) of
  Left err       -> Left err
  Right (ty, cs, _) -> case runSolve cs of
    Left err    -> Left err
    Right subst -> Right (closeOver $ apply subst ty)

-- | Return internal constraints used in solving for type of expression
constraintsExpr :: TypeEnv
                -> Expr
                -> Either TypeError ([Constraint], Subst, Type, Scheme)
constraintsExpr env ex = case runInfer env (infer ex) of
  Left       err -> Left err
  Right (ty, cs, _) -> case runSolve cs of
    Left err    -> Left err
    Right subst -> Right (cs, subst, ty, sc)
      where sc = closeOver $ apply subst ty

closeOver :: Type -> Scheme
closeOver = normalize . generalize emptyTyEnv

inEnv :: (Name, Scheme) -> Infer a -> Infer a
inEnv (x, sc) m = do
  let scope e = removeTyEnv e x `extendTyEnv` (x, sc)
  local scope m

lookupEnv :: Name -> Infer Type
lookupEnv x = do
  TypeEnv env <- ask
  case Map.lookup x env of
    Nothing -> throwError $ UnboundVariable x
    Just tyA  -> instantiate tyA

letters :: [String]
letters = [1..] >>= flip replicateM ['a'..'z']

fresh :: (String -> a) -> Infer a
fresh f = do
  s <- get
  put s{count = count s + 1}
  return $ f (letters !! count s)

--freshifyt :: Map.Map TVar TVar -> Type -> Infer (Type, Map.Map TVar TVar)
--freshifyt env t@(TVar _) = return (t, env)
--freshifyt env t@(TCon _) = return (t, env)
--freshifyt env (TArr t1 t2) = do
--  (t1', env1) <- freshifyt env t1
--  (t2', env2) <- freshifyt env1 t2
--  return (TArr t1' t2', env2)
--freshifyt env (TList t) = do
--  (t', env') <- freshifyt env t
--  return (TList t', env')
--freshifyt env (TProd ts) = do
--  (TProd ts', env') <- foldM (\(TProd acc, e) t -> (freshifyt e t) >>=
--                       \(t', e') -> return (TProd (t':acc), e)) (TProd [], env) ts
--  return (TProd (reverse ts'), env')
--freshifyt env (TWrChan t) = do
--  (t', env') <- freshifyt env t
--  return (TWrChan t', env')
--freshifyt _ _ = error "Infer.freshifyt"

instantiate :: Scheme -> Infer Type
instantiate (Forall as t) = do
    as' <- mapM (const (fresh (IType . IVar . TV))) as
    let s = Subst $ Map.fromList $ zip as as'
    return $ apply s t

--instantiate :: Scheme -> Infer Type
--instantiate (Forall as t) = do
--  as' <- mapM (const (fresh (TVar . TV))) as
--  let s = Subst $ Map.fromList $ zip as as'
--      s' = apply s t
--  (s'', _) <- freshifyt Map.empty s'
--  return s''

generalize :: TypeEnv -> Type-> Scheme -- ^ T-Gen
generalize env t = Forall as t
  where as = Set.toList $ ftv t `Set.difference` ftv env

binops :: Binop -> Infer Type
binops Add = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyInt))))
binops Sub = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyInt))))
binops Mul = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyInt))))
binops Div = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyInt))))
binops Mod = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyInt))))
binops And = return $ IType (IArr tyBool (IType (IArr tyBool (IType tyBool))))
binops Or  = return $ IType (IArr tyBool (IType (IArr tyBool (IType tyBool))))
binops Lt  = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyBool))))
binops Gt  = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyBool))))
binops Leq = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyBool))))
binops Geq = return $ IType (IArr tyInt (IType (IArr tyInt (IType tyBool))))
binops Eql = eqbinop
binops Neq = eqbinop
binops _   = error "Infer.binops"

eqbinop :: Infer Type
eqbinop = do
  t1 <- fresh (IVar . TV)
  t2 <- fresh (IVar . TV)
  return $ IType (IArr t1 (IType (IArr t2 (IType tyBool))))

unops :: Unop -> Type
unops Not = IType (IArr tyBool (IType tyBool))

concatTCEs :: [(Type, [Constraint], [(Name, Type)])]
           -> ([Type], [Constraint], [(Name, Type)])
concatTCEs = foldr f ([], [], [])
  where
    f (t, c, e) (t', c', e') = (t : t', c ++ c', e ++ e')

concatTCs :: [(Type, [Constraint])] -> ([Type], [Constraint])
concatTCs = foldr f ([], [])
  where
    f (t, c) (t', c') = (t : t', c ++ c')

inferPatList :: [Pattern]
             -> [Maybe Expr]
             -> Infer ([Type], [Constraint], [(Name, Type)])
inferPatList pats exprs = do
  tces <- zipWithM inferPat pats exprs
  return $ concatTCEs tces

listConstraints :: [Type]
                -> [Constraint]
                -> Infer (Type, [Constraint])
listConstraints ts cs = do
  thd <- fresh (IVar . TV)
  return $ if null ts
           then (IType thd, cs)
           else (head ts, cs ++ (map (IType thd,) ts))
        
inferPat :: Pattern
         -> Maybe Expr
         -> Infer (Type, [Constraint], [(Name, Type)])
inferPat pat expr = case (pat, expr) of
  (PVar x, Just e) -> do
    (ty, cs, _) <- infer e
    case ty of
      IType _ -> do
        tv <- fresh (IType . IVar . TV)
        return (tv, (tv, ty) : cs, [(x, tv)])
      AType _ -> do
        tv <- fresh (AType . AVar . TV)
        return (tv, (tv, ty) : cs, [(x, tv)])        
    
  (PVar x, Nothing) -> do
    tv <- fresh (AVar . TV)
    return (AType tv, [], [(x, AType tv)])

--  (PInt _, Just e) -> do
--    (te, ce, _) <- infer e
--    let constraints = (te, tyInt) : ce
--    return (tyInt, constraints, [])
--  (PInt _, Nothing) -> return (tyInt, [], [])
--
--  (PBool _, Just e) -> do
--    (te, ce, _) <- infer e
--    let constraints = (te, tyBool) : ce
--    return (tyBool, constraints, [])
--  (PBool _, Nothing) -> return (tyBool, [], [])
--
--  (PString _, Just e) -> do
--    (te, ce, _) <- infer e
--    let constraints = (te, tyString) : ce
--    return (tyString, constraints, [])
--  (PString _, Nothing) -> return (tyString, [], [])
--
--  (PTuple ps, Just (ETuple es)) -> do
--    when (length ps /= length es) (error "fail") -- TODO: -- Custom error
--    (tes, ces, _) <- infer $ ETuple es
--    (ts, cs, env) <- inferPatList ps $ map Just es
--    let constraints = (TProd ts, tes) : ces ++ cs
--    return (TProd ts, constraints, env)
--  (PTuple ps, Just e) -> do
--    (ts, cs, env) <- inferPatList ps $ repeat Nothing
--    (te, ce, _) <- infer e
--    let constraints = (TProd ts, te) : cs ++ ce
--    return (TProd ts, constraints, env)
--  (PTuple ps, Nothing) -> do
--    (ts, cs, env) <- inferPatList ps $ repeat Nothing
--    return (TProd ts, cs, env)
--
--  (PList ps, Just (EList es)) -> do
--    when (length ps /= length es) (error "fail") -- TODO
--    (tes, ces, _) <- infer $ EList es
--    (ts, cs, env) <- inferPatList ps $ map Just es
--    (thd, cs') <- listConstraints ts cs
--    let constraints = (TList thd, tes) : ces ++ cs'
--    return (TList thd, constraints, env)
--  (PList ps, Just e) -> do
--    (te, ce, _) <- infer e
--    (ts, cs, env) <- inferPatList ps $ repeat Nothing
--    (thd, cs') <- listConstraints ts cs
--    let constraints = (TList thd, te) : ce ++ cs'
--    return (TList thd, constraints, env)
--  (PList ps, Nothing) -> do
--    tces <- zipWithM inferPat ps $ repeat Nothing
--    let (ts, cs, env) = concatTCEs tces
--    (thd, cs') <- listConstraints ts cs
--    return (TList thd, cs', env)
--
--  (PCons phd ptl, Just e@(EList (hd:tl))) -> do
--    (te, ce, _) <- infer e
--    (thd, chd, ehd) <- inferPat phd $ Just hd
--    (ttl, ctl, etl) <- inferPat ptl $ Just $ EList tl
--    let cs = ce ++ chd ++ ctl ++ [ (TList thd, te)
--                                 , (te, ttl) ]
--        env = ehd ++ etl
--    return (TList thd, cs, env)
--  (PCons phd ptl, Just e) -> do
--    (te, ce, _) <- infer e
--    (thd, chd, ehd) <- inferPat phd Nothing
--    (ttl, ctl, etl) <- inferPat ptl Nothing
--    let cs = ce ++ chd ++ ctl ++ [ (TList thd, te)
--                                 , (te, ttl)
--                                 , (TList thd, ttl) ]
--        env = ehd ++ etl
--    return (TList thd, cs, env)
--  (PCons phd ptl, Nothing) -> do
--    (thd, chd, ehd) <- inferPat phd Nothing
--    (ttl, ctl, etl) <- inferPat ptl Nothing
--    let cs = (TList thd, ttl) : chd ++ ctl
--        env = ehd ++ etl
--    return (TList thd, cs, env)
--
  (PUnit, Just e) -> do
    (ty, cs,  _) <- infer e
    return (IType tyUnit, (ty, IType tyUnit) : cs, [])
  (PUnit, Nothing) -> return (IType tyUnit, [], [])

  (PWildcard, _) -> do
    return (IType tyUnit, [], [])
--
--  (PCust x ps, Just (ECustom x' es)) -> do
--    tyx <- lookupEnv x
--    let tyx' = typeSumDeconstruction tyx ps
--    when (length ps /= length es) (error "fail1") -- TODO
--    when (x /= x') (error "fail2") -- TODO
--    (ts, cs, env) <- inferPatList ps $ map Just es
--    return (tyx', cs, env)
--  (PCust x ps, Just e) -> do
--    tyx <- lookupEnv x
--    let tyx' = typeSumDeconstruction tyx ps
--    (te, ce, _) <- infer e
--    (ts, cs, env) <- inferPatList ps $ repeat Nothing
--    let constraints = (tyx', te) : ce ++ cs
--    return (tyx', constraints, env)
--  (PCust x ps, Nothing) -> do
--    tyx <- lookupEnv x
--    let tyx' = typeSumDeconstruction tyx ps
--    tces <- zipWithM inferPat ps $ repeat Nothing
--    let (ts, cs, env) = concatTCEs tces
--    return (tyx', cs, env)

-- | This function computes the type of a deconstructed sum type. The type of a
-- value constructor should either be an arrow type leading to a custom type
-- constructor (in the non-nullary case) or simply the custom type constructor
-- itself (in the nullary case).
-- TODO: Error handling.
typeSumDeconstruction :: Type -> [Pattern] -> Type
typeSumDeconstruction (IType (IArr _ t)) (p:ps) = typeSumDeconstruction t ps
typeSumDeconstruction t            []     = t
typeSumDeconstruction _            _      = error "Infer:typeSumDeconstruction"

sumTypeBinds :: [Pattern] -> Type -> [(Name, Type)] -> [(Name, Type)]
sumTypeBinds (PVar x:ps) (IType (IArr t t'@(IType IArr{}))) env =
  sumTypeBinds ps t' ((x, (IType t)) : env)
sumTypeBinds (PVar x:ps) (IType (IArr t _))         env = (x, (IType t)) : env
sumTypeBinds _           _                    env = env

inferBranch :: Expr
            -> (Pattern, Expr, Expr)
            -> Infer (Type, [Constraint], TypeEnv)
inferBranch expr (pat, guard, branch) = do
  env <- ask
  (_, c1, binds) <- inferPat pat $ Just expr
  (_, _, _Γ2) <- infer expr
  case runSolve c1 of
    Left err -> throwError err
    Right sub -> do
      let sc t = generalize (apply sub env) (apply sub t)
      (t2, c2, _Γ3) <- local (const _Γ2) (foldr (\(x, t) -> inEnv (x, sc t))
                        (local (apply sub) (infer guard))
                        binds)
      (t3, c3, _Γ4) <- local (const _Γ3) (foldr (\(x, t) -> inEnv (x, sc t))
                        (local (apply sub) (infer branch))
                        binds)
      let _Γ4' = foldl (\_Γ (x, _) -> removeTyEnv _Γ x) _Γ4 binds
          tyConstraints = (t2, IType tyBool) :c1 ++ c2 ++ c3
          constraints = tyConstraints
      return (t3, constraints, _Γ4')

sameThings :: Eq a => [a] -> Either TypeError a
sameThings (m:ms) = if (all (m ==) ms) then Right m else Left (TypeFail "Not same things.")

infers :: ([Type], [Constraint], TypeEnv) -> [Expr] -> Infer ([Type], [Constraint], TypeEnv)
infers = foldM (\(tys, cs, ctxt) e -> do
                   (ty', cs', ctxt') <- local (const ctxt) (infer e) 
                   return (ty' : tys, cs ++ cs', ctxt'))

infer :: Expr -> Infer (Type, [Constraint], TypeEnv)
infer expr = case expr of
  EVar x -> do
    ctxt <- ask    
    t    <- lookupEnv x
    let ctxt' = case t of
          IType _ -> ctxt
          AType _ -> removeTyEnv ctxt x
    return (t, [], ctxt')

  ELit (LInt _) -> do
    ctxt <- ask
    return (IType tyInt, [], ctxt)

  ELit (LBool _) -> do
    ctxt <- ask
    return (IType tyBool, [], ctxt)
    
  ELit (LString _) -> do
    ctxt <- ask
    return (IType tyString, [], ctxt)
  
  ELit LUnit -> do
    ctxt <- ask
    return (IType tyUnit, [], ctxt)
    
  ETuple es -> do
    ctxt1 <- ask
    (tys, cs, ctxt2) <- infers ([],[],ctxt1) es
    return (IType . IProd . (map  (\(IType x) -> x)) . reverse $ tys, cs, ctxt2)

  EList [] -> do
    ctxt <- ask
    ty <- fresh (IType . IList . IVar . TV)
    return (ty, [], ctxt)

  EList es -> do
    ctxt1 <- ask
    (tys, cs1, ctxt2) <- infers ([],[],ctxt1) es    
    let tyHd = (\(IType x) -> x) (head tys)
        cs2  = map (IType tyHd,) tys
    return (IType . IList $ tyHd, cs1 ++ cs2, ctxt2)

  EBin Cons e1 e2  -> do
   (IType tyA, cs1, ctxt2) <- infer e1
   (tyALst, cs2, ctxt3) <- local (const ctxt2) (infer e2)
   return (tyALst, (IType (IList tyA), tyALst) : cs1 ++ cs2, ctxt3)

  EBin Concat e1 e2  -> do
   (tyA, cs1, ctxt2) <- infer e1
   (tyB, cs2, ctxt3) <- local (const ctxt2) (infer e2)
   return (tyA, (tyA, tyB) : cs1 ++ cs2, ctxt3)

  EBin op e1 e2 -> do
    (IType tyA, cs1, ctxt2) <- infer e1
    (IType tyB, cs2, ctxt3) <- local (const ctxt2) (infer e2)
    tv <- fresh (IType . IVar . TV)
    let u1 = IType (IArr tyA (IType (IArr tyB tv)))
    u2 <- binops op
    let cs = cs1 ++ cs2 ++ [(u1, u2), (IType tyA, IType tyB)]
    return (tv, cs, ctxt3)

  EUn op e -> do
    (IType tyA, cs, ctxt2) <- infer e
    tv <- fresh (IType . IVar . TV)
    let u1 = IType (IArr tyA tv)
        u2 = unops op
    return (tv, (u1,u2) : cs, ctxt2)

  EIf e1 e2 e3 -> do
    (tyA1, cs1, ctxt2) <- infer e1
    (tyA2, cs2, ctxt3) <- local (const ctxt2) (infer e2)
    (tyA3, cs3, ctxt3') <- local (const ctxt2) (infer e3)
    let cs = cs1 ++ cs2 ++ cs3 ++ [(tyA1, IType tyBool), (tyA2, tyA3)]
    return (tyA2, cs, intersectTyEnv ctxt3 ctxt3')

  ELet p e1 e2 -> do
    ctxt1 <- ask
    (_, cs1, binds) <- inferPat p $ Just e1
    (_, cs2, ctxt2) <- infer e1
    case runSolve cs1 of
      Left err -> throwError err
      Right sub -> do
        let sc t = generalize (apply sub ctxt1) (apply sub t)
        (tyU, cs3, ctxt3) <- local (const ctxt2) (foldr (\(x, t) -> inEnv (x, sc t))
                              (local (apply sub) (infer e2))
                              binds)
        return (tyU, cs1 ++ cs2 ++ cs3, ctxt3)
--
--  ELetBang p e1 e2 -> do
--    env <- ask
--    tyV <- fresh (TVar . TV)
--    (_, c1, binds) <- inferPatLin p $ Just e1
--    (tye1, _, _Γ2) <- infer e1
--    let c1' = (tye1, (TLin (LBang tyV))) : c1
--    case runSolve c1' of
--      Left err -> throwError err
--      Right sub -> do
--        let sc t = generalize (apply sub env) (apply sub t)
--        (tyB, c2, _Γ3) <- local (const _Γ2) (foldr (\(x, t) -> inEnv (x, sc t))
--                              (local (apply sub) (infer e2))
--                              binds)
--        let tyConstraints = c1' ++ c2
--            constraints = tyConstraints
--        return (tyB, constraints, _Γ3)

  EBang e -> do
    (IType tyA, cs, ctxt2) <- infer e
    return (AType (ABang tyA), cs, ctxt2)

--  ELetRd (PTuple [PVar v, PVar c]) (ERd e1) e2 -> do
--    env <- ask
--    tyV <- fresh (TVar . TV)
--    let binds = [(v, TLin (LBang tyV)), (c, TLin (LRdChan tyV))]
--    (tye1, c1, _Γ2) <- infer (ERd e1)
--    let c1' = TypeConstraint (TLin (LTensor (LBang tyV) (LRdChan tyV))) tye1 : c1
--    case runSolve c1' of
--      Left err -> throwError err
--      Right sub -> do
--        let sc t = generalize (apply sub env) (apply sub t)
--        (tyB, c2, _Γ3) <- (local (const _Γ2) (foldr (\(x, t) -> inEnv (x, sc t))
--                              (local (apply sub) (infer e2))
--                              binds))
--        let tyConstraints = c1' ++ c2
--            constraints = tyConstraints
--        return (tyB, constraints, _Γ3)
--
--  -- TODO: Reduce duplication
--  ELetRd (PTuple [PWildcard, PVar c]) (ERd e1) e2 -> do
--    env <- ask
--    tyV <- fresh (TVar . TV)
--    let binds = [(c, TLin (LRdChan tyV))]
--    (tye1, c1, _Γ2) <- infer (ERd e1)
--    let c1' = TypeConstraint (TLin (LTensor (LBang tyV) (LRdChan tyV))) tye1 : c1
--    case runSolve c1' of
--      Left err -> throwError err
--      Right sub -> do
--        let sc t = generalize (apply sub env) (apply sub t)
--        (tyB, c2, _Γ3) <- (local (const _Γ2) (foldr (\(x, t) -> inEnv (x, sc t))
--                              (local (apply sub) (infer e2))
--                              binds))
--        let tyConstraints = c1' ++ c2
--            constraints = tyConstraints
--        return (tyB, constraints, _Γ3)
--
--  ELetRd PWildcard (ERd e1) e2 -> do
--    env <- ask
--    tyV <- fresh (TVar . TV)
--    let binds = []
--    (tye1, c1, _Γ2) <- infer (ERd e1)
--    let c1' = TypeConstraint (TLin (LTensor (LBang tyV) (LRdChan tyV))) tye1 : c1
--    case runSolve c1' of
--      Left err -> throwError err
--      Right sub -> do
--        let sc t = generalize (apply sub env) (apply sub t)
--        (tyB, c2, _Γ3) <- (local (const _Γ2) (foldr (\(x, t) -> inEnv (x, sc t))
--                              (local (apply sub) (infer e2))
--                              binds))
--        let tyConstraints = c1' ++ c2
--            constraints = tyConstraints
--        return (tyB, constraints, _Γ3)
--
--  EMatch e bs -> do
--    tcmes <- mapM (inferBranch e) bs
--    let (ts, cs, _Γs) = concatTCEs tcmes
--        ty       = head ts
--        cs'      = map (`TypeConstraint` ty) (tail ts)
--    -- TODO: Clean up
--    let envs = map (\case {TypeEnv binds -> Map.filter (\x -> x == Forall []
--    TUsed) binds}) _Γs
--    _ <- case sameThings envs  of
--             Left err -> throwError err
--             Right _Γ  -> return _Γ
--    let tyConstraints = cs ++ cs'
--        constraints = tyConstraints
--    return (ty, constraints, head _Γs)
--
--  ELam (PVar x) e -> do
--    tyV <- fresh (TVar . TV)
--    (tyA, c, _Γ2) <- inEnv (x, Forall [] tyV) (infer e)
--    (tyV', tyA') <- case runSolve c of
--             Left err -> throwError err
--             Right sub -> return (apply sub tyV, apply sub tyA)
--    case (tyV', tyA') of
--      (TLin lV', TLin lA') -> return (TLin (LArr lV' lA'), c, V, _Γ2)
--      (TLin lV', t)        -> return (TLin (LArr lV' (linearize t)), c, V, _Γ2)
--      _                    -> return (TArr tyV' tyA', c, V, _Γ2)
--
--  ELam PUnit e -> do
--    (tyA, c, _Γ2) <- infer e
--    tyA' <- case runSolve c of
--              Left err -> throwError err
--              Right sub -> return $ apply sub tyA
--    case tyA' of
--      TLin lA' ->
--        return (TLin (LArr (LBang tyUnit) lA'), c, _Γ2)
--      _                    ->
--        return (TArr tyUnit tyA' m, c, _Γ2)
--
--  {-ELam PUnit e -> do
--    (tyA, c, m, _Γ2) <- infer e
--    return (TArr tyUnit tyA m, c, V, _Γ2)-}
--
--  ELam PWildcard e -> do
--    tyV <- fresh (TVar . TV)
--    (tyA, c, _Γ2) <- infer e
--    return (TArr tyV tyA m , c,  _Γ2)
--
--  ELam _ _ -> error "Infer.infer: ELam"
--
--  EFix e -> do
--    (tyA2A, c,  _Γ2) <- infer e
--    tyA2A' <- case runSolve c of
--             Left err -> throwError err
--             Right sub -> return $ apply sub tyA2A
--    (tyRes, tyConstraints) <- case tyA2A' of
--      TLin l -> do
--        tyV <- fresh (LVar . TV)
--        return (TLin tyV, TypeConstraint tyA2A (TLin (LArr tyV tyV)) : c)
--      _      -> do
--        tyV <- fresh (TVar . TV)
--        return (tyV, TypeConstraint tyA2A (TArr tyV tyV) : c)
--    let constraints = tyConstraints
--    return (tyRes, constraints, _Γ2)
--    
--  EApp e1 e2 -> do
--    (tyA, c1, _Γ2) <- infer e2
--    (tyA2B, c2, _Γ3) <- local (const _Γ2) (infer e1)
--    (tyA2B', tyA') <- case runSolve (c1 ++ c2) of
--             Left err -> throwError err
--             Right sub -> return (apply sub tyA2B, apply sub tyA)
--    (tyRet, tyConstraints) <- case (tyA2B', tyA') of
--          (t, TLin l) -> do
--            tyV <- fresh (LVar . TV)
--            tyA'' <- fresh (LVar . TV)
--            return (TLin tyV, TypeConstraint tyA2B (TLin (LArr tyA'' tyV)) : TypeConstraint (TLin tyA'') tyA : c1 ++ c2)
--          (TLin l, t) -> do
--            tyV  <- fresh (LVar . TV)
--            tyA'' <- fresh (LVar . TV)
--            return (TLin tyV, TypeConstraint tyA2B (TLin (LArr tyA'' tyV)) : TypeConstraint (TLin tyA'') tyA : c1 ++ c2)
--          (t1, t2)    -> do
--            tyV <- fresh (TVar . TV)
--            return  (tyV, TypeConstraint tyA2B (TArr tyA tyV) : c1 ++ c2)
--    let constraints = tyConstraints
--    return (tyRet, constraints, _Γ3)
--
--  ERd e -> do
--    (tyA, c, _Γ2) <- infer e
--    tyV <- fresh (TVar . TV)
--    let tyConstraints = TypeConstraint tyA (TLin (LRdChan tyV)) : c
--        constraints = tyConstraints
--    return (TLin (LTensor (LBang tyV) (LRdChan tyV)), constraints, _Γ2)

  EWr e1 e2 -> do
    (IType (ISend tyS), cs1, ctxt2) <- infer e1
    (tyWrS, cs2, ctxt3) <- local (const ctxt2) (infer e2)
    return (IType tyUnit, (IType (IWrChan tyS), tyWrS) : cs1 ++ cs2, ctxt3)

  ENu (rdc, wrc) e -> do
    tyV <- fresh (SVar . TV)
    let newChans = [ (rdc, Forall [] $ AType (ARdChan tyV))
                   , (wrc, Forall [] $ IType (IWrChan tyV))]
    (tyU, cs, ctxt2) <- foldr inEnv (infer e) newChans
    return (tyU, cs , ctxt2)
    
  EFork e1 e2 -> do
    (_, cs1, ctxt2) <- infer e1
    (tyV, cs2, ctxt3) <- local (const ctxt2) (infer e2)
    return (tyV, cs1 ++ cs2,ctxt3)

  EChoice e1 e2 -> do
    (tyU1, cs1, ctxt2) <- infer e1
    (tyU2, cs2, ctxt3) <- infer e2
    return (tyU1, (tyU1, tyU2) : cs1 ++ cs2, intersectTyEnv ctxt2 ctxt3)

  EPrint e -> do
    (_, cs, ctxt2) <- infer e
    return (IType tyUnit, cs, ctxt2)

--  TODO: Universal type variable
--  EError e  -> do
--    tv <- fresh (IVar . TV)
--    (IType tyString, cs, ctxt2) <- infer e
--    return (tv, cs, ctxt2)

  ECustom x es -> do
    ctxt1 <- ask
    tyx <- lookupEnv x
    (tys, cs, ctxt2) <- infers ([],[],ctxt1) es
    return (tyx, [], ctxt2)

inferTop :: TypeEnv -> [(Name, Expr)] -> Either TypeError TypeEnv
inferTop env [] = Right env
inferTop env ((name, ex):xs) = case inferExpr env ex of
  Left err -> Left err
  Right ty -> inferTop (extendTyEnv env (name, ty)) xs

normalize :: Scheme -> Scheme
normalize (Forall _ body) = Forall (map snd ord) (normtype body)
  where
    ord = zip (nub $ fv body) (map TV letters)

    fv (IType a) = fvi a
    fv (AType a) = fva a

    fvi (IVar a) = [a]
    fvi (ICon _) = []
    fvi (IProd as) = concatMap fvi as    
    fvi (IArr a b) = fvi a ++ fv b
    fvi (IList a) = fvi a
    fvi (IWrChan a) = fvs a
    fvi (ICust a) = fvi a
    fvi (ISend a) = fvs a

    fva (AVar a) = [a]
    fva (ARdChan a) = fvs a
    fva (AProd as) = concatMap fva as
    fva (ABang a) = fvi a

    fvs (SVar a) = [a]
    fvs (SProd as) = concatMap fvs as
    fvs (SCon _) = []

    normtype (IType a) = IType (normtypei a)
    normtype (AType a) = AType (normtypea a)
    
    normtypei (IVar a)   =
        case Prelude.lookup a ord of
            Just x -> IVar x
            Nothing -> error "type variable not in signature"
    normtypei (ICon a)   = ICon a
    normtypei (IProd as)   = IProd (map normtypei as)    
    normtypei (IArr a b) = IArr (normtypei a) (normtype b)
    normtypei (IList a)   = IList (normtypei a)
    normtypei (IWrChan a)   = IWrChan (normtypes a)
    normtypei (ICust a)   = ICust (normtypei a)
    normtypei (ISend a)   = ISend (normtypes a)

    normtypea (AVar a)   =
        case Prelude.lookup a ord of
            Just x -> AVar x
            Nothing -> error "type variable not in signature"
    normtypea (AProd as)   = AProd (map normtypea as)
    normtypea (ABang a)   = ABang (normtypei a)    
    normtypea (ARdChan a)   = ARdChan (normtypes a)

    normtypes (SVar a)   =
        case Prelude.lookup a ord of
            Just x -> SVar x
            Nothing -> error "type variable not in signature"
    normtypes (SProd as)   = SProd (map normtypes as)                
    normtypes (SCon a)   = SCon a
    
-------------------------------------------------------------------------------
-- Constraint Solver
-------------------------------------------------------------------------------

emptySubst :: Subst
emptySubst = mempty

compose :: Subst -> Subst -> Subst
(Subst s1) `compose` (Subst s2) = Subst $ Map.map (apply (Subst s1)) s2 `Map.union` s1

runSolve :: [Constraint] -> Either TypeError Subst
runSolve cs = runIdentity $ runExceptT $ solver st
  where st = (emptySubst, cs)

unifies :: Type -> Type -> Solve Subst
unifies t1 t2 | t1 == t2 = return emptySubst
unifies (IType t1) (IType t2) = unifiesi t1 t2
unifies (AType t1) (AType t2) = unifiesa t1 t2
unifies t1 t2 = throwError $ UnificationFail t1 t2

unifiesi :: IType -> IType -> Solve Subst
unifiesi t1 t2 | t1 == t2 = return emptySubst
unifiesi (IVar v) t = v `bindi` t
unifiesi t (IVar v) = v `bindi` t
unifiesi (IProd ts1) (IProd ts2) = unifyManyi ts1 ts2
unifiesi (IArr t1 t2) (IArr t3 t4) = do
  (Subst s1) <- unifiesi t1 t3
  (Subst s2) <- unifies t2 t4
  return $ Subst $ s1 `Map.union` s2
unifiesi (IList t1) (IList t2) = unifiesi t1 t2
unifiesi (IWrChan t1) (IWrChan t2) = unifiess t1 t2
unifiesi (ICust t1) (ICust t2) = unifiesi t1 t2
unifiesi (ISend t1) (ISend t2) = unifiess t1 t2
unifiesi t1 t2 = throwError $ UnificationFail (wrap t1) (wrap t2)
  where
    wrap = IType

unifiesa :: AType -> AType -> Solve Subst
unifiesa t1 t2 | t1 == t2 = return emptySubst
unifiesa (AVar v) t = v `binda` t
unifiesa t (AVar v) = v `binda` t
unifiesa (ARdChan t1) (ARdChan t2) = unifiess t1 t2
unifiesa (AProd ts1) (AProd ts2) = unifyManya ts1 ts2
unifiesa (ABang t1) (ABang t2) = unifiesi t1 t2
unifiesa t1 t2 = throwError $ UnificationFail (wrap t1) (wrap t2)
  where
    wrap = AType

unifiess :: SType -> SType -> Solve Subst
unifiess t1 t2 | t1 == t2 = return emptySubst
unifiess (SVar v) t = v `binds` t
unifiess t (SVar v) = v `binds` t
unifiess (SProd ts1) (SProd ts2) = unifyManys ts1 ts2
unifiess t1 t2 = throwError $ UnificationFail (wrap t1) (wrap t2)
  where
    wrap = IType . ISend

unifyMany :: [Type] -> [Type] -> Solve Subst
unifyMany [] []  = return emptySubst
unifyMany t1@(IType{} : _) t2@(IType{} : _) = unifyManyi t1' t2'
  where
    t1' = map strip t1
    t2' = map strip t2
    strip = \(IType t) -> t
unifyMany t1@(AType{} : _) t2@(AType{} : _) = unifyManya t1' t2'
  where
    t1' = map strip t1
    t2' = map strip t2
    strip = \(AType t) -> t
unifyMany t1 t2 = throwError $ UnificationMismatch t1 t2

unifyManyi :: [IType] -> [IType] -> Solve Subst
unifyManyi [] []  = return emptySubst
unifyManyi (t1 : ts1) (t2 : ts2) =
  do su1 <- unifiesi t1 t2
     su2 <- unifyManyi (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyManyi t1 t2 = throwError $ UnificationMismatch t1' t2'
  where
    t1' = map IType t1
    t2' = map IType t2

unifyManya :: [AType] -> [AType] -> Solve Subst
unifyManya [] []  = return emptySubst
unifyManya (t1 : ts1) (t2 : ts2) =
  do su1 <- unifiesa t1 t2
     su2 <- unifyManya (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyManya t1 t2 = throwError $ UnificationMismatch t1' t2'
  where
    t1' = map AType t1
    t2' = map AType t2

unifyManys :: [SType] -> [SType] -> Solve Subst
unifyManys [] []  = return emptySubst
unifyManys (t1 : ts1) (t2 : ts2) =
  do su1 <- unifiess t1 t2
     su2 <- unifyManys (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyManys t1 t2 = throwError $ UnificationMismatch t1' t2'
  where
    t1' = map (IType . ISend) t1
    t2' = map (IType . ISend) t2

solver :: Unifier -> Solve Subst
solver (su, cs) =
  case cs of
    [] -> return su
    ((t1, t2) : cs') -> do
      su1 <- unifies t1 t2
      solver (su1 `compose` su, apply su1 cs')

bindi :: TVar -> IType -> Solve Subst
bindi a t | t == IVar a     = return emptySubst
          | occursCheck a t = throwError $ InfiniteType a (IType t)
          | otherwise       = return (Subst $ Map.singleton a (IType t))

binda :: TVar -> AType -> Solve Subst
binda a t | t == AVar a     = return emptySubst
          | occursCheck a t = throwError $ InfiniteType a (AType t)
          | otherwise       = return (Subst $ Map.singleton a (AType t))

binds :: TVar -> SType -> Solve Subst
binds a t | t == SVar a     = return emptySubst
          | occursCheck a t = throwError $ InfiniteType a (IType (ISend t))
          | otherwise       = return (Subst $ Map.singleton a (IType (ISend t)))          

occursCheck :: Substitutable a => TVar -> a -> Bool
occursCheck a t = a `Set.member` ftv t
