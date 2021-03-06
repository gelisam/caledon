{-# LANGUAGE  
 FlexibleInstances,
 PatternGuards,
 UnicodeSyntax,
 BangPatterns
 #-}
module HOU where

import Choice
import AST
import Context
import TopoSortAxioms
import Control.Monad.State (StateT, forM_,runStateT, modify, get)
import Control.Monad.RWS (RWST, runRWST, ask, tell)
import Control.Monad.Error (throwError, MonadError)
import Control.Monad (unless, forM, replicateM, void, (<=<))
import Control.Monad.Trans (lift)
import Control.Applicative
import qualified Data.Foldable as F
import Data.List
import Data.Maybe
import Data.Monoid
import qualified Data.Map as M
import qualified Data.Set as S
import Debug.Trace

import System.IO.Unsafe

{-# INLINE level #-}
level = 0

{-# INLINE vtrace #-}
vtrace !i | i < level = trace
vtrace !i = const id

{-# INLINE vtraceShow #-}
vtraceShow !i1 !i2 s v | i2 < level = trace $ s ++" : "++show v
vtraceShow !i1 !i2 s v | i1 < level = trace s
vtraceShow !i1 !i2 s v = id

{-# INLINE throwTrace #-}
throwTrace !i s = vtrace i s $ throwError s

mtrace True = trace
mtrace False = const id


-----------------------------------------------
---  the higher order unification algorithm ---
-----------------------------------------------

flatten :: Constraint -> Env [SCons]
flatten (Bind quant nm ty c) = do
  modifyCtxt $ addToTail "-flatten-" quant nm ty
  flatten c
flatten (c1 :&: c2) = do
  l1 <- flatten c1
  l2 <- flatten c2
  return $ l1 ++ l2
flatten (SCons l) = return l

type UnifyResult = Maybe (Substitution, [SCons])

unify :: Constraint -> Env Substitution
unify cons =  do
  cons <- vtrace 5 ("CONSTRAINTS1: "++show cons) $ regenAbsVars cons
  cons <- vtrace 5 ("CONSTRAINTS2: "++show cons) $ flatten cons
  let uniWhile :: Substitution -> [SCons] -> Env (Substitution, [SCons])
      uniWhile !sub !c' = fail "" <|> do
        exists <- getExists       
        c <- regenAbsVars c'     
        let uniWith !wth !backup = searchIn c []
              where searchIn [] r = finish Nothing
                    searchIn (next:l) r = 
                      wth next $ \c1' -> case c1' of
                            Just (sub',next') -> finish $ Just (sub', subst sub' (reverse r)++next'++subst sub' l)
                            Nothing -> searchIn l $ next:r
                    finish Nothing = backup
                    finish (Just (!sub', c')) = do
                      let !sub'' = sub *** sub'
                      modifyCtxt $ subst sub'
                      uniWhile sub'' $! c'
              
              
        vtrace 3 ("CONST: "++show c)
          ( uniWith unifyOne 
          $ uniWith unifySearch
          $ uniWith unifySearchAtom
          $ checkFinished c >> 
          return (sub, c))

  fst <$> uniWhile mempty cons


checkFinished [] = return ()
checkFinished cval = throwTrace 0 $ "ambiguous constraint: " ++show cval

unifySearch :: SCons -> CONT_T b Env UnifyResult
unifySearch (a :@: b) return | b /= atom = rightSearch a b $ newReturn return
unifySearch _ return = return Nothing

newReturn return cons = return $ case cons of
  Nothing -> Nothing
  Just cons -> Just (mempty, cons)

unifySearchAtom :: SCons -> CONT_T b Env UnifyResult
unifySearchAtom (a :@: b) return = rightSearch a b $ newReturn return
unifySearchAtom _ return = return Nothing



unifyOne :: SCons -> CONT_T b Env UnifyResult
unifyOne (a :=: b) return = do
  c' <- isolateForFail $ unifyEq $ a :=: b 
  case c' of 
    Nothing -> return =<< (isolateForFail $ unifyEq $ b :=: a)
    r -> return r
unifyOne _ return = return Nothing

unifyEq cons@(a :=: b) = case (a,b) of 
  (Spine "#imp_forall#" [ty, l], b) -> vtrace 1 "-implicit-" $ do
    a' <- getNewWith "@aL"
    modifyCtxt $ addToTail "-implicit-" Exists a' ty
    return $ Just (mempty, [l `apply` var a' :=: b , var a' :@: ty])
  (b, Spine "#imp_forall#" [ty, l]) -> vtrace 1 "-implicit-" $ do
    a' <- getNewWith "@aR"
    modifyCtxt $ addToTail "-implicit-" Exists a' ty
    return $ Just (mempty,  [b :=: l `apply` var a' , var a' :@: ty])

  (Spine "#imp_abs#" (ty:l:r), b) -> vtrace 1 ("-imp_abs- : "++show a ++ "\n\t"++show b) $ do
    a <- getNewWith "@iaL"
    modifyCtxt $ addToTail "-imp_abs-" Exists a ty
    return $ Just (mempty, [rebuildSpine l (var a:r) :=: b , var a :@: ty])
  (b, Spine "#imp_abs#" (ty:l:r)) -> vtrace 1 "-imp_abs-" $ do
    a <- getNewWith "@iaR"
    modifyCtxt $ addToTail "-imp_abs-" Exists a ty
    return $ Just (mempty, [b :=: rebuildSpine l (var a:r) , var a :@: ty])

  (Spine "#tycon#" [Spine nm [_]], Spine "#tycon#" [Spine nm' [_]]) | nm /= nm' -> throwTrace 0 $ "different type constraints: "++show cons
  (Spine "#tycon#" [Spine nm [val]], Spine "#tycon#" [Spine nm' [val']]) | nm == nm' -> 
    return $ Just (mempty, [val :=: val'])

  (Abs nm ty s , Abs nm' ty' s') -> vtrace 1 "-aa-" $ do
    modifyCtxt $ addToTail "-aa-" Forall nm ty
    return $ Just (mempty, [ty :=: ty' , s :=: subst (nm' |-> var nm) s'])
  (Abs nm ty s , s') -> vtraceShow 1 2 "-asL-" cons $ do
    modifyCtxt $ addToTail "-asL-" Forall nm ty
    return $ Just (mempty, [s :=: s' `apply` var nm])

  (s, Abs nm ty s' ) -> vtraceShow 1 2 "-asR-" cons $ do
    modifyCtxt $ addToTail "-asR-" Forall nm ty
    return $ Just (mempty, [s `apply` var nm :=: s'])

  (s , s') | s == s' -> vtrace 1 "-eq-" $ return $ Just (mempty, [])
  (s@(Spine x yl), s') -> vtrace 4 "-ss-" $ do
    bind <- getElm ("all: "++show cons) x
    case bind of
      Left bind@Binding{ elmQuant = Exists } -> vtrace 4 "-g?-" $ do
        raiseToTop bind (Spine x yl) $ \(a@(Spine x yl),ty) sub ->
          case subst sub s' of
            b@(Spine x' y'l) -> vtrace 4 "-gs-" $ do
              bind' <- getElm ("gvar-blah: "++show cons) x' 
              case bind' of
                Right ty' -> vtraceShow 1 2 "-gc-" cons $ -- gvar-const
                  --if allElementsAreVariables yl
                  --then gvar_const (Spine x yl, ty) (Spine x' y'l, ty')  
                  -- else return Nothing
                  gvar_const (Spine x yl, ty) (Spine x' y'l, ty') 
                Left Binding{ elmQuant = Forall } | not $ S.member x' $ freeVariables yl -> 
                  throwTrace 0 $ "CANT: gvar-uvar-depends: "++show (a :=: b)
                Left Binding{ elmQuant = Forall } | S.member x $ freeVariables y'l -> 
                  throwTrace 0 $ "CANT: occurs check: "++show (a :=: b)
                Left Binding{ elmQuant = Forall, elmType = ty' } -> vtrace 1 "-gui-" $  -- gvar-uvar-inside
                  gvar_uvar_inside (Spine x yl, ty) (Spine x' y'l, ty')
                Left bind@Binding{ elmQuant = Exists, elmType = ty' } -> 
                  if not $ allElementsAreVariables yl && allElementsAreVariables y'l 
                  then return Nothing 
                  else if x == x' 
                       then vtraceShow 1 2 "-ggs-" cons $ -- gvar-gvar-same
                         gvar_gvar_same (Spine x yl, ty) (Spine x' y'l, ty')
                       else -- gvar-gvar-diff
                         if S.member x $ freeVariables y'l 
                         then throwTrace 0 $ "CANT: ggd-occurs check: "++show (a :=: b)
                         else vtraceShow 1 2 "-ggd-" cons $ gvar_gvar_diff (Spine x yl, ty) (Spine x' y'l, ty') bind
            _ -> vtrace 1 "-ggs-" $ return Nothing
      _ -> vtrace 4 "-u?-" $ case s' of 
        b@(Spine x' _) | x /= x' -> do
          bind' <- getElm ("const case: "++show cons) x'
          case bind' of
            Left Binding{ elmQuant = Exists } -> return Nothing
            _ -> throwTrace 0 ("CANT: -uud- two different universal equalities: "++show (a :=: b)) -- uvar-uvar 

        Spine x' yl' | x == x' -> vtraceShow 1 2 "-uue-" (a :=: b) $ do -- uvar-uvar-eq
          
          let match ((Spine "#tycon#" [Spine nm [a]]):al) bl = case findTyconInPrefix nm bl of
                Nothing -> match al bl
                Just (b,bl) -> ((a :=: b) :) <$> match al bl
          -- in this case we know that al has no #tycon#s in its prefix since we exhausted all of them in the previous case
              match al (Spine "#tycon#" [Spine _ [_]]:bl) = match al bl 
              match (a:al) (b:bl) = ((a :=: b) :) <$> match al bl 
              match [] [] = return []
              match _ _ = throwTrace 0 $ "CANT: different numbers of arguments on constant: "++show cons

          cons <- match yl yl'
          return $ Just (mempty, cons)
        _ -> throwTrace 0 $ "CANT: uvar against a pi WITH CONS "++show cons
            
allElementsAreVariables :: [Spine] -> Bool
allElementsAreVariables = all $ \c -> case c of
  Spine _ [] -> True
  _ -> False

typeToListOfTypes (Spine "#forall#" [_, Abs x ty l]) = (x,ty):typeToListOfTypes l
typeToListOfTypes (Spine _ _) = []
typeToListOfTypes a@(Abs _ _ _) = error $ "not a type" ++ show a

-- the problem WAS (hopefully) here that the binds were getting
-- a different number of substitutions than the constraints were.
-- make sure to check that this is right in the future.
raiseToTop bind@Binding{ elmName = x, elmType = ty } sp m = do
  
  hl <- reverse <$> getBindings bind
  x' <- getNewWith "@newx"
  
  let newx_args = map (var . fst) hl
      sub = x |-> Spine x' newx_args
      
      ty' = foldr (\(nm,ty) a -> forall nm ty a) ty hl
        
      addSub Nothing = return Nothing
      addSub (Just (sub',cons)) = do
        -- we need to solve subst twice because we might reify twice
        let sub'' = ((subst sub' <$> sub) *** sub') 

        modifyCtxt $ subst sub'
        return $ Just (sub'', cons)
        
  modifyCtxt $ addToHead "-rtt-" Exists x' ty' . removeFromContext x
  vtrace 3 ("RAISING: "++x' ++" +@+ "++ show newx_args ++ " ::: "++show ty'
         ++"\nFROM: "++x ++" ::: "++ show ty
          ) modifyCtxt $ subst sub
  
  -- now we can match against the right hand side
  r <- addSub =<< m (subst sub sp, ty') sub
  modifyCtxt $ removeFromContext x'
  return r

      
getBase 0 a = a
getBase n (Spine "#forall#" [_, Abs _ _ r]) = getBase (n - 1) r
getBase _ a = a

makeBind xN us tyl arg = foldr (uncurry Abs) (Spine xN $ map var arg) $ zip us tyl

gvar_gvar_same (a@(Spine x yl), aty) (b@(Spine _ y'l), _) = do
  aty <- regenAbsVars aty
  let n = length yl
         
      (uNl,atyl) = unzip $ take n $ typeToListOfTypes aty
      
  xN <- getNewWith "@ggs"
  
  let perm = [iyt | (iyt,_) <- filter (\(_,(a,b)) -> a == b) $ zip (zip uNl atyl) (zip yl y'l) ]
      
      l = makeBind xN uNl atyl $ map fst perm
      
      xNty = foldr (uncurry forall) (getBase n aty) perm
      
      sub = x |-> l
      
  modifyCtxt $ addToHead "-ggs-" Exists xN xNty -- THIS IS DIFFERENT FROM THE PAPER!!!!
  
  return $ Just (sub, []) -- var xN :@: xNty])
  
gvar_gvar_same _ _ = error "gvar-gvar-same is not made for this case"

gvar_gvar_diff (a',aty') (sp, _) bind = raiseToTop bind sp $ \(b'@(Spine x' y'l), bty) subO -> do
  
  let (Spine x yl, aty) = (subst subO a', subst subO aty')

      -- now x' comes before x 
      -- but we no longer care since I tested it, and switching them twice reduces to original
      n = length yl
      m = length y'l
      
  aty <- regenAbsVars aty
  bty <- regenAbsVars bty
  
  let (uNl,atyl) = unzip $ take n $ typeToListOfTypes aty
      (vNl,btyl) = unzip $ take m $ typeToListOfTypes bty
      
  xN <- getNewWith "@ggd"
  
  let perm = do
        (iyt,y) <- zip (zip uNl atyl) yl
        (i',_) <- filter (\(_,y') -> y == y') $ zip vNl y'l 
        return (iyt,i')
      
      l = makeBind xN uNl atyl $ map (fst . fst) perm
      l' = makeBind xN vNl btyl $ map snd perm
      
      xNty = foldr (uncurry forall) (getBase n aty) (map fst perm)
      
      sub = M.fromList [(x ,l), (x',l')]

  modifyCtxt $ addToHead "-ggd-" Exists xN xNty -- THIS IS DIFFERENT FROM THE PAPER!!!!
  
  vtrace 3 ("SUBST: -ggd- "++show sub) $ return $ Just (sub, []) -- var xN :@: xNty])
  
gvar_uvar_inside a@(Spine _ yl, _) b@(Spine y _, _) = 
  case elemIndex (var y) $ reverse yl of
    Nothing -> return Nothing
    Just _ -> gvar_uvar_outside a b
gvar_uvar_inside _ _ = error "gvar-uvar-inside is not made for this case"
  
gvar_const a@(s@(Spine x yl), _) b@(s'@(Spine y _), bty) = vtrace 3 (show a++"   ≐   "++show b) $
  case elemIndex (var y) $ yl of 
    Nothing -> gvar_fixed a b $ var . const y
    Just _ -> do
     gvar_uvar_outside a b <|> gvar_fixed a b (var . const y) 

gvar_const _ _ = error "gvar-const is not made for this case"

gvar_uvar_outside a@(s@(Spine x yl),_) b@(s'@(Spine y _),bty) = do
  let ilst = [i | (i,y') <- zip [0..] yl , y' == var y] 
  i <- F.asum $ return <$> ilst
  gvar_fixed a b $ (!! i) 


gvar_uvar_outside _ _ = error "gvar-uvar-outside is not made for this case"

getTyNews (Spine "#forall#" [_, Abs _ _ t]) = Nothing:getTyNews t
getTyNews (Spine "#imp_forall#" [_, Abs nm _ t]) = Just nm:getTyNews t
getTyNews _ = []

gvar_fixed (a@(Spine x _), aty) (b@(Spine _ y'l), bty) action = do
  let m = getTyNews bty -- max (length y'l) (getTyLen bty)
      cons = a :=: b
--      getNewTys "@xm" bty 

  
  let getArgs (Spine "#forall#" [ty, Abs ui _ r]) = ((var ui,ui),Left ty):getArgs r
      getArgs (Spine "#imp_forall#" [ty, Abs ui _ r]) = ((tycon ui $ var ui,ui),Right ty):getArgs r
      getArgs _ = []
      
      untylr = getArgs aty
      (un,_) = unzip untylr 
      (vun, _) = unzip un
  
  xm <- forM m $ \j -> do
    x <- getNewWith "@xm"
    return (x, (Spine x vun, case j of
      Nothing -> Spine x vun
      Just a -> tycon a $ Spine x vun))  
      
  let xml = map (snd . snd) xm
      -- when rebuilding the spine we want to use typeconstructed variables if bty contains implicit quantifiers
      toLterm (Spine "#forall#" [ty, Abs ui _ r]) = Abs ui ty $ toLterm r
      toLterm (Spine "#imp_forall#" [ty, Abs ui _ r]) = imp_abs ui ty $ toLterm r      
      toLterm _ = rebuildSpine (action vun) $ xml

      
      l = toLterm aty
  
      vbuild e = foldr (\((_,nm),ty) a -> case ty of
                           Left ty -> forall nm ty a
                           Right ty -> imp_forall nm ty a
                       ) e untylr

      substBty sub (Spine "#forall#" [_, Abs vi bi r]) ((x,xi):xmr) = (x,vbuild $ subst sub bi)
                                                                :substBty (M.insert vi (fst xi) sub) r xmr
      substBty sub (Spine "#imp_forall#" [_, Abs vi bi r]) ((x,xi):xmr) = (x,vbuild $ subst sub bi)
                                                                    : substBty (M.insert vi (fst xi) sub) r xmr
      substBty _ _ [] = []
      substBty _ s l  = error $ "is not well typed: "++show s
                        ++"\nFOR "++show l 
                        ++ "\nON "++ show cons
      
      sub = x |-> l -- THIS IS THAT STRANGE BUG WHERE WE CAN'T use x in the output substitution!
      addExists s t = vtrace 3 ("adding: "++show s++" ::: "++show t) $ addToHead "-gf-" Exists s t
  modifyCtxt $ flip (foldr ($)) $ uncurry addExists <$> substBty mempty bty xm  
  modifyCtxt $ subst sub
  
  return $ Just (sub, [subst sub $ a :=: b])

gvar_fixed _ _ _ = error "gvar-fixed is not made for this case"

--------------------
--- proof search ---  
--------------------


-- need bidirectional search!
rightSearch :: Term -> Type -> CONT_T b Env (Maybe [SCons])
rightSearch m goal ret = vtrace 1 ("-rs- "++show m++" ∈ "++show goal) $ fail (show m++" ∈ "++show goal) <|>
  case goal of
    Spine "#forall#" [a, b] -> do
      y <- getNewWith "@sY"
      x' <- getNewWith "@sX"
      let b' = b `apply` var x'
      modifyCtxt $ addToTail "-rsFf-" Forall x' a
      modifyCtxt $ addToTail "-rsFe-" Exists y b'
      ret $ Just [ var y :=: m `apply` var x' , var y :@: b']

    Spine "#imp_forall#" [_, Abs x a b] -> do
      y <- getNewWith "@isY"
      x' <- getNewWith "@isX"
      let b' = subst (x |-> var x') b
      modifyCtxt $ addToTail "-rsIf-" Forall x' a        
      modifyCtxt $ addToTail "-rsIe-" Exists y b'
      ret $ Just [ var y :=: m `apply` (tycon x $ var x')
                 , var y :@: b'
                 ]
    Spine "putChar" [c@(Spine ['\'',l,'\''] [])] -> ret $ Just $ (m :=: Spine "putCharImp" [c]):seq action []
      where action = unsafePerformIO $ putStr $ l:[]

    Spine "putChar" [_] -> vtrace 0 "FAILING PUTCHAR" $ ret Nothing
  
    Spine "readLine" [l] -> 
      case toNCCstring $ unsafePerformIO $ getLine of
        s -> do -- ensure this is lazy so we don't check for equality unless we have to.
          y <- getNewWith "@isY"
          let ls = l `apply` s
          modifyCtxt $ addToTail "-rl-" Exists y ls
          ret $ Just [m :=: Spine "readLineImp" [l,s {- this is only safe because lists are lazy -}, var y], var y :@: Spine "run" [ls]]
    _ | goal == kind -> do
      case m of
        Abs{} -> throwError "not properly typed"
        _ | m == tipe || m == atom -> ret $ Just []
        _ -> breadth -- we should pretty much always use breadth first search here maybe, since this is type search
          where srch r1 r2 = r1 $ F.asum $ r2 . Just . return . (m :=:) <$> [atom , tipe] -- for breadth first
                breadth = srch (ret =<<) return
                depth = srch id (appendErr "" . ret)
          
    Spine nm _ -> do
      constants <- getConstants
      foralls <- getForalls
      exists <- getExists
      let env = M.union foralls constants
      
          isFixed a = isChar a || M.member a env
      
          getFixedType a | isChar a = Just $ anonymous $ var "char"
          getFixedType a = M.lookup a env
      
      let mfam = case m of 
            Abs{} -> Nothing
            Spine nm _ -> case getFixedType nm of
              Just t -> Just (nm,t)
              Nothing -> Nothing

          sameFamily (_, (_,Abs{})) = False
          sameFamily ("pack",_) = "#exists#" == nm
          sameFamily (_,(_,s)) = getFamily s == nm
          
      targets <- case mfam of
        Just (nm,t) -> return $ [(nm,t)]
        Nothing -> do
          let excludes = S.toList $ S.intersection (M.keysSet exists) $ freeVariables m
          searchMaps <- mapM getVariablesBeforeExists excludes
          
          let searchMap :: ContextMap
              searchMap = M.union env $ case searchMaps of
                [] -> mempty
                a:l -> foldr (M.intersection) a l
                
          return $ filter sameFamily $ M.toList searchMap
      
      if all isFixed $ S.toList $ S.union (freeVariables m) (freeVariables goal)
        then ret $ Just []
        else case targets of
          [] -> ret Nothing
          _  -> inter [] $ sortBy (\a b -> compare (getVal a) (getVal b)) targets
            where ls (nm,target) = leftSearch (m,goal) (var nm, target)
                  getVal = snd . fst . snd
                  
                  inter [] [] = throwError "no more options"
                  inter cg [] = F.asum $ reverse cg
                  inter cg ((nm,((sequ,_),targ)):l) = do
                    res <- Just <$> ls (nm,targ)
                    if sequ 
                      then (if not $ null cg then (appendErr "" (F.asum $ reverse cg) <|>) else id) $ 
                           (appendErr "" $ ret res) <|> inter [] l
                      else inter (ret res:cg) l
                      
                      
a .-. s = foldr (\k v -> M.delete k v) a s 

leftSearch (m,goal) (x,target) = vtrace 1 ("LS: " ++ show x++" ∈ " ++show target++" >> " ++show m ++" ∈ "++ show goal)
                               $ leftCont x target
  where leftCont n target = case target of
          Spine "#forall#" [a, b] -> do
            x' <- getNewWith "@sla"
            modifyCtxt $ addToTail "-lsF-" Exists x' a
            cons <- leftCont (n `apply` var x') (b `apply` var x')
            return $ cons++[var x' :@: a]

          Spine "#imp_forall#" [_ , Abs x a b] -> do  
            x' <- getNewWith "@isla"
            modifyCtxt $ addToTail "-lsI-" Exists x' a
            cons <- leftCont (n `apply` (tycon x $ var x')) (subst (x |-> var x') b)
            return $ cons++[var x' :@: a]
          Spine _ _ -> do
            return $ [goal :=: target, m :=: n]
          _ -> error $ "λ does not have type atom: " ++ show target


search :: Type -> Env (Substitution, Term)
search ty = do
  e <- getNewWith "@e"
  sub <- unify $ (∃) e ty $ SCons [var e :@: ty]
  return $ (sub, subst sub $ var e)

-----------------------------
--- constraint generation ---
-----------------------------

(≐) a b = lift $ tell $ SCons [a :=: b]
(.@.) a b = lift $ tell $ SCons [a :@: b]

withKind m = do
  k <- getNewWith "@k"
  addToEnv (∃) k kind $ do
    r <- m $ var k
    var k .@. kind
    return r

check v x = if x == "13@regm+f" then trace ("FOUND AT: "++ v) x else x

checkType :: Spine -> Type -> TypeChecker Spine
checkType sp ty | ty == kind = withKind $ checkType sp
checkType sp ty = case sp of
  Spine "#hole#" [] -> do
    x' <- getNewWith "@hole"
    addToEnv (∃) x' ty $ do
      var x' .@. ty
      return $ var x'
      
  Spine "#ascribe#" (t:v:l) -> do
    (v'',mem) <- regenWithMem v
    
    t'' <- regenAbsVars t
    v' <- checkType v'' t''
    
    r <- getNewWith "@r"
    Spine _ l' <- addToEnv (∀) r t $ checkType (Spine r l) ty
    return $ rebuildSpine (rebuildFromMem mem v') l'

--    checkType (rebuildSpine (rebuildFromMem mem v') l) ty
    
  Spine "#infer#" [_, Abs x tyA tyB ] -> do
    tyA <- withKind $ checkType tyA
    
    x' <- getNewWith "@inf"
    addToEnv (∃) x' tyA $ do
      var x' .@. tyA
      checkType (subst (x |-> var x') tyB) ty

  Spine "#imp_forall#" [_, Abs x tyA tyB] -> do
    tyA <- withKind $ checkType tyA
    tyB <- addToEnv (∀) (check "imp_forall" x) tyA $ checkType tyB ty
    return $ imp_forall x tyA tyB
    
  Spine "#forall#" [_, Abs x tyA tyB] -> do
    tyA <- withKind $ checkType tyA
    forall x tyA <$> (addToEnv (∀) (check "forall" x) tyA $ 
      checkType tyB ty )

  -- below are the only cases where bidirectional type checking is useful 
  Spine "#imp_abs#" [_, Abs x tyA sp] -> case ty of
    Spine "#imp_forall#" [_, Abs x' tyA' tyF'] -> do
      unless ("" == x' || x == x') $ 
        lift $ throwTrace 0 $ "can not show: "++show sp ++ " : "++show ty 
                           ++"since: "++x++ " ≠ "++x'
      tyA <- withKind $ checkType tyA
      tyA ≐ tyA'
      addToEnv (∀) (check "impabs1" x) tyA $ do
        imp_abs x tyA <$> checkType sp tyF'
        
    _ -> do
      e <- getNewWith "@e"
      tyA <- withKind $ checkType tyA
      withKind $ \k -> addToEnv (∃) e (forall x tyA k) $ do
        imp_forall x tyA (Spine e [var x]) ≐ ty
        sp <- addToEnv (∀) (check "impabs2" x) tyA $ checkType sp (Spine e [var x])
        return $ imp_abs x tyA $ sp

  Abs x tyA sp -> case ty of
    Spine "#forall#" [_, Abs x' tyA' tyF'] -> do
      tyA <- withKind $ checkType tyA
      tyA ≐ tyA'
      addToEnv (∀) (check "abs1" x) tyA $ do
        Abs x tyA <$> checkType sp (subst (x' |-> var x) tyF')
    _ -> do
      e <- getNewWith "@e"
      tyA <- withKind $ checkType tyA
      withKind $ \k -> addToEnv (∃) e (forall "" tyA k) $ do
        forall x tyA (Spine e [var x]) ≐ ty
        Abs x tyA <$> (addToEnv (∀) (check "abs2" x) tyA $ checkType sp (Spine e [var x]))
  Spine nm [] | isChar nm -> do
    ty ≐ Spine "char" []
    return sp
  Spine head args -> do
    let chop mty [] = do
          ty ≐ mty
          return []
          
        chop mty lst@(a:l) = case mty of 
          
          Spine "#imp_forall#" [ty', Abs nm _ tyv] -> case findTyconInPrefix nm lst of
            Nothing -> do
              x <- getNewWith "@xin"
              addToEnv (∃) x ty' $ do
                var x .@. ty' 
                -- we need to make sure that the type is satisfiable such that we can reapply it!
                (tycon nm (var x):) <$> chop (subst (nm |-> var x) tyv) lst

            Just (val,l) -> do
              val <- checkType val ty'
              (tycon nm val:) <$> chop (subst (nm |-> val) tyv) l
          Spine "#forall#" [ty', c] -> do
            a <- checkType a ty'
            (a:) <$> chop (c `apply` a) l
          _ -> withKind $ \k -> do  
            x <- getNewWith "@xin"
            z <- getNewWith "@zin"
            tybody <- getNewWith "@v"
            let tybodyty = forall z (var x) k
            withKind $ \k' -> addToEnv (∃) x k' $ addToEnv (∃) tybody tybodyty $ do 
              a <- checkType a (var x)
              v <- getNewWith "@v"
              forall v (var x) (Spine tybody [var v]) ≐ mty
              (a:) <$> chop (Spine tybody [a]) l

    mty <- (M.lookup head) <$> lift getFullCtxt
    
    case mty of 
      Nothing -> lift $ throwTrace 0 $ "variable: "++show head++" not found in the environment."
                                     ++ "\n\t from "++ show sp
                                     ++ "\n\t from "++ show ty
      Just ty' -> Spine head <$> chop (snd ty') args

checkFullType :: Spine -> Type -> Env (Spine, Constraint)
checkFullType val ty = typeCheckToEnv $ checkType val ty

----------------------
--- type inference ---
----------------------
typeInfer :: ContextMap -> ((Bool,Integer),Name,Spine,Type) -> Choice (Term,Type, ContextMap)
typeInfer env (seqi,nm,val,ty) = (\r -> (\(a,_,_) -> a) <$> runRWST r (M.union envConsts env) emptyState) $ do
  ty <- return $ alphaConvert mempty ty
  val <- return $ alphaConvert mempty val
  
  (ty,mem') <- regenWithMem ty
  (val,mem) <- regenWithMem val
  
  (val,constraint) <- checkFullType val ty
  
  sub <- appendErr ("which became: "++show val ++ "\n\t :  " ++ show ty) $ 
         unify constraint
  
  let resV = rebuildFromMem mem $ unsafeSubst sub val
      resT = rebuildFromMem mem' $ unsafeSubst sub ty

  vtrace 0 ("RESULT: "++nm++" : "++show resV) $
      return $ (resV,resT, M.insert nm (seqi,resV) env)

unsafeSubst s (Spine nm apps) = let apps' = unsafeSubst s <$> apps in case s ! nm of 
  Just nm -> rebuildSpine nm apps'
  _ -> Spine nm apps'
unsafeSubst s (Abs nm tp rst) = Abs nm (unsafeSubst s tp) (unsafeSubst s rst)
  
----------------------------
--- the public interface ---
----------------------------

type FlatPred = [(Maybe Name,(Bool,Integer,Bool),Name,Term,Type)]
typeCheckAxioms :: Bool -> FlatPred -> Choice Substitution
typeCheckAxioms verbose lst = do
  
  -- check the closedness of families.  this gets done
  -- after typechecking since family checking needs to evaluate a little bit
  -- in order to allow defs in patterns
  let notval (_,_,'#':'v':':':_,_,_) = False
      notval (_,_,_,_,_) = True 
      
      unsound (_,(_,_,s),_,_,_) = not s
      
      tys = M.fromList $ map (\(_,(b,i,_),nm,ty,_) -> (nm,((b,i),ty))) $ filter notval lst
      uns = S.fromList $ map (\(_,_,nm,ty,_) -> nm) $ filter unsound $ filter notval lst
      
      inferAll :: (ContextMap, FlatPred, FlatPred) -> Choice (FlatPred,ContextMap)
      inferAll (l , r, []) = return (r,l)
      inferAll (_ , r, (_,_,nm,_,_):_) | nm == tipeName = throwTrace 0 $ tipeName++" can not be overloaded"
      inferAll (_ , r, (_,_,nm,_,_):_) | nm == atomName = throwTrace 0 $ atomName++" can not be overloaded"
      inferAll (l , r, (fam,(b,i,s),nm,val,ty):toplst) = do
        (val,ty,l') <- appendErr ("can not infer type for: "++nm++" : "++show val) $ 
                       mtrace verbose ("Checking: " ++nm) $ 
                       vtrace 0 ("\tVAL: " ++show val  
                                 ++"\n\t:: " ++show ty) $
                       typeInfer l ((b,i),nm, val,ty) -- constrain the breadth first search to be local!
                    
        -- do the family check after ascription removal and typechecking because it can involve computation!
        unless (fam == Nothing || Just (getFamily val) == fam)
          $ throwTrace 0 $ "not the right family: need "++show fam++" for "++nm ++ " = " ++show val                    
          
        inferAll $ case nm of
          '#':'v':':':nm' -> (sub' <$> l', (fam,(b,i,s),nm,val,ty):r , fsub <$> toplst) 
            where sub' (b,a)= (b, sub a)
                  sub = subst $ nm' |-> ascribe val ty -- the ascription isn't necessary because we don't have unbound variables
                  fsub (fam,s,nm,val,ty) = (fam,s,nm, sub val, sub ty)
          _ -> (l', (fam,(b,i,s),nm,val,ty):r, toplst)

  (lst',l) <- inferAll (tys, [], topoSortAxioms lst)
  
  let doubleCheckAll _ [] = return ()
      doubleCheckAll l ((_,_,nm,val,ty):r) = do
        let usedvars = freeVariables val `S.union` freeVariables ty
        unless (S.isSubsetOf usedvars l)
          $ throwTrace 0 $ "Circular type:"
                        ++"\n\t"++nm++" : "++show val ++" : "++show ty
                        ++"\n\tcontains the following circular type dependencies: "
                        ++"\n\t"++show (S.toList $ S.difference usedvars l)
                        ++ "\nPossible Solution: declare it unsound"
                        ++ "\nunsound "++nm++" : "++show val
        doubleCheckAll (S.insert nm l) r
  
  doubleCheckAll (S.union envSet uns) $ topoSortAxioms lst'
  
  return $ snd <$> l 
  
typeCheckAll :: Bool -> [Predicate] -> Choice [Predicate]
typeCheckAll verbose preds = do

  tyMap <- typeCheckAxioms verbose $ toAxioms True preds
  
  let newPreds (Predicate t nm _ cs) = Predicate t nm (tyMap M.! nm) $ map (\(b,(nm,_)) -> (b,(nm, tyMap M.! nm))) cs
      newPreds (Query nm _) = Query nm (tyMap M.! nm)
      newPreds (Define t nm _ _) = Define t nm (tyMap M.! ("#v:"++nm)) (tyMap M.! nm)
  
  return $ newPreds <$> preds

toAxioms :: Bool -> [Predicate] -> [(Maybe [Char], (Bool, Integer, Bool), Name, Type, Spine)]  
toAxioms b = concat . zipWith toAxioms' [0..]
  where toAxioms' j (Predicate s nm ty cs) = (Just $ atomName,(False,j,s),nm,ty,tipe):zipWith (\(sequ,(nm',ty')) i -> (Just nm,(sequ,i,False), nm',ty',atom)) cs [0..]
        toAxioms' j (Query nm val) = [(Nothing, (False,j,False),nm,val,atom)]
        toAxioms' j (Define s nm val ty) = (if b then ((Nothing,(False,j,s), "#v:"++nm,val,ty):) else id)
                                           [(Nothing,(False,j,False), nm,ty,kind)] 
  
toSimpleAxioms :: [Predicate] -> ContextMap
toSimpleAxioms l = M.fromList $ (\(_,(seqi,i,_),nm,t,_) -> (nm,((seqi,i),t))) <$> toAxioms False l

solver :: ContextMap -> Type -> Either String [(Name, Term)]
solver axioms tp = case runError $ runRWST (search tp) (M.union envConsts axioms) emptyState of
  Right ((_,tm),_,_) -> Right $ [("query", tm)]
  Left s -> Left $ "reification not possible: "++s
