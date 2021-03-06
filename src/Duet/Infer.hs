{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | A clear-to-read, well-documented, implementation of a Haskell 98
-- type checker adapted from Typing Haskell In Haskell, by Mark
-- P. Jones.

module Duet.Infer
  (
  -- * Type checker
  -- $type-checker
    typeCheckModule
  , byInst
  , InferException(..)
  -- * Setting up
  , addClass
  , addInstance
  , SpecialTypes(..)
  , ReadException(..)
  -- * Printers
  -- , printTypeSignature
  -- * Types syntax tree
  , Type(..)
  , Kind(..)
  , Scheme(..)
  , TypeSignature(..)
  , TypeVariable(..)
  , Qualified(..)
  , Class(..)
  , Predicate(..)
  , TypeConstructor(..)
  -- * Values syntax tree
  , ImplicitlyTypedBinding(..)
  , ExplicitlyTypedBinding(..)
  , Expression(..)
  , Literal(..)
  , Pattern(..)
  , BindGroup(..)
  , Alternative(..)
  , toScheme
  , typeKind
  , classMethodScheme
  ) where

import           Control.Arrow (first,second)
import           Control.Monad.Catch
import           Control.Monad.State
import           Data.Generics
import           Data.Graph
import           Data.List
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Maybe
import           Duet.Types

--------------------------------------------------------------------------------
-- Type inference
--

-- $type-checker
--
-- The type checker takes a module and produces a list of type
-- signatures. It checks that all types unify, and infers the types of
-- unannotated expressions. It resolves type-class instances.

-- | Type check the given module and produce a list of type
-- signatures.
--
-- >>> fmap (map printTypeSignature) (typeCheckModule mempty [] [BindGroup [] [[ImplicitlyTypedBinding (Identifier "id") [Alternative [VariablePattern (Identifier "x")] (VariableExpression (Identifier "x"))]]]])
-- ["id :: forall a0. a0 -> a0"]
--
-- Throws 'InferException' in case of a type error.
typeCheckModule ::
     (MonadThrow m)
  => Map Name (Class Type Name Label) -- ^ Set of defined type-classes.
  -> [(TypeSignature Type Name Name)] -- ^ Pre-defined type signatures e.g. for built-ins or FFI.
  -> SpecialTypes Name -- ^ Special types that Haskell uses for pattern matching and literals.
  -> [Binding Type Name Label] -- ^ Bindings in the module.
  -> m ( [BindGroup Type Name (TypeSignature Type Name Label)]
       , Map Name (Class Type Name (TypeSignature Type Name Label)))
typeCheckModule ce as specialTypes bgs0 = do
  (bgs, classes) <- runTypeChecker (dependencyAnalysis bgs0)
  pure (bgs, classes)
  where
    runTypeChecker bgs =
      evalStateT
        (runInferT $ do
           instanceBgs <- classMethodsToGroups specialTypes ce
           (ps, _, bgs') <-
             inferSequenceTypes inferBindGroupTypes ce as (bgs ++ instanceBgs)
           s <- InferT (gets inferStateSubstitutions)
           let rs = reduce ce (map (substitutePredicate s) ps)
           s' <- defaultSubst ce [] rs
           let bgsFinal = map (fmap (substituteTypeSignature (s' @@ s))) bgs'
           ce' <- collectMethods bgsFinal ce
           return (bgsFinal, ce'))
        (InferState nullSubst 0 specialTypes)

-- | Sort the list of bindings by order of no-dependencies first
-- followed by things that depend on them. Group bindings that are
-- mutually recursive.
dependencyAnalysis :: Data l => [Binding Type Name l] -> [BindGroup Type Name l]
dependencyAnalysis = map toBindGroup . stronglyConnComp . bindingsGraph
  where
    toBindGroup =
      \case
        AcyclicSCC binding ->
          BindGroup (explicits [binding]) [implicits [binding]]
        CyclicSCC bindings ->
          BindGroup (explicits bindings) [implicits bindings]
    explicits =
      mapMaybe
        (\case
           ExplicitBinding i -> Just i
           _ -> Nothing)
    implicits =
      mapMaybe
        (\case
           ImplicitBinding i -> Just i
           _ -> Nothing)

-- | Make a graph of the bindings with their dependencies.
bindingsGraph :: Data l => [Binding Type Name l] -> [(Binding Type Name l, Name, [Name])]
bindingsGraph =
  map
    (\binding ->
       ( binding
       , bindingIdentifier binding
       , listify
           (\case
              n@ValueName {} -> n /= bindingIdentifier binding
              _ -> False)
           (bindingAlternatives binding)))

collectMethods ::
     forall l m. MonadThrow m
  => [BindGroup Type Name (TypeSignature Type Name l)]
  -> Map Name (Class Type Name l)
  -> m (Map Name (Class Type Name (TypeSignature Type Name l)))
collectMethods binds =
  fmap M.fromList .
  mapM
    (\(name, cls) -> do
       insts <-
         mapM
           (\inst -> do
              methods <-
                mapM
                  collectMethod
                  (M.toList (dictionaryMethods (instanceDictionary inst)))
              pure
                inst
                { instanceDictionary =
                    (instanceDictionary inst)
                    {dictionaryMethods = M.fromList methods}
                })
           (classInstances cls)
       pure (name, cls {classInstances = insts})) .
  M.toList
  where
    collectMethod ::
         (Name, (l, t))
      -> m ( Name
           , ( TypeSignature Type Name l
             , Alternative Type Name (TypeSignature Type Name l)))
    collectMethod (key, (l, _)) =
      case listToMaybe
             (mapMaybe
                (\(BindGroup ex _) ->
                   listToMaybe
                     (mapMaybe
                        (\i ->
                           if fst (explicitlyTypedBindingId i) == key
                             then listToMaybe
                                    (explicitlyTypedBindingAlternatives i)
                             else Nothing)
                        ex))
                binds) of
        Just alt ->
          pure
            ( key
            , ( TypeSignature l (typeSignatureScheme (alternativeLabel alt))
              , alt))
        Nothing -> throwM MissingMethod

classMethodsToGroups
  :: MonadThrow m
  => SpecialTypes Name -> Map Name (Class Type Name l) -> m [BindGroup Type Name l]
classMethodsToGroups specialTypes =
  mapM
    (\class' ->
       BindGroup <$>
       fmap
         concat
         (mapM
            (\inst ->
               sequence
                 (zipWith
                    (\methodScheme (instMethodName, (l, methodAlt)) ->
                       ExplicitlyTypedBinding <$> pure l <*>
                       pure (instMethodName, l) <*>
                       instanceMethodScheme
                         specialTypes
                         class'
                         methodScheme
                         (instancePredicate inst) <*>
                       pure [methodAlt])
                    (M.elems (classMethods class'))
                    (M.toList (dictionaryMethods (instanceDictionary inst)))))
            (classInstances class')) <*>
       pure []) .
  M.elems

instanceMethodScheme
  :: MonadThrow m
  => SpecialTypes Name
  -> Class Type Name l
  -> Scheme Type Name Type
  -> Scheme Type Name (Predicate Type)
  -> m (Scheme Type Name Type)
instanceMethodScheme _specialTypes cls (Forall methodVars0 (Qualified methodPreds methodType0)) _instScheme@(Forall instanceVars0 (Qualified preds (IsIn _ headTypes))) = do
  methodQual <- instantiateQual (Qualified (methodPreds ++ preds) methodType0)
  pure (Forall methodVars methodQual)
  where
    methodVars = filter (not . flip elem (classTypeVariables cls)) (methodVars0 ++ instanceVars0)
    table = zip (classTypeVariables cls) headTypes
    instantiateQual (Qualified ps t) =
      Qualified <$> mapM instantiatePred ps <*> instantiate t
    instantiatePred (IsIn c t) = IsIn c <$> mapM instantiate t
    instantiate =
      \case
        ty@(VariableType tyVar) ->
          case lookup tyVar table of
            Nothing -> pure ty
            Just typ -> pure typ
        ApplicationType a b ->
          ApplicationType <$> instantiate a <*> instantiate b
        typ -> pure typ

classMethodScheme
  :: MonadThrow m
  => Class t Name l -> Scheme Type Name Type -> m (Scheme Type Name Type)
classMethodScheme cls (Forall methodVars (Qualified methodPreds methodType)) = do
  ty' <- pure methodType
  headVars <- mapM (pure . VariableType) (classTypeVariables cls)
  pure
    (Forall
       methodVars
       (Qualified (methodPreds ++ [IsIn (className cls) headVars]) ty'))

--------------------------------------------------------------------------------
-- Substitution

infixr 4 @@
(@@) :: [Substitution Name] -> [Substitution Name] -> [Substitution Name]
s1 @@ s2 = [Substitution u (substituteType s1 t) | (Substitution u t) <- s2] ++ s1

nullSubst :: [Substitution Name]
nullSubst = []

substituteQualified :: [Substitution Name] -> Qualified Type Name (Type Name) -> Qualified Type Name (Type Name)
substituteQualified substitutions (Qualified predicates t) =
  Qualified
    (map (substitutePredicate substitutions) predicates)
    (substituteType substitutions t)

substituteTypeSignature :: [Substitution Name] -> (TypeSignature Type Name l) -> (TypeSignature Type Name l)
substituteTypeSignature substitutions (TypeSignature l scheme) =
    TypeSignature l (substituteInScheme substitutions scheme)
  where substituteInScheme subs' (Forall kinds qualified) =
          Forall kinds (substituteQualified subs' qualified)

substitutePredicate :: [Substitution Name] -> Predicate Type Name -> Predicate Type Name
substitutePredicate substitutions (IsIn identifier types) =
    IsIn identifier (map (substituteType substitutions) types)

substituteType :: [Substitution Name] -> Type Name -> Type Name
substituteType substitutions (VariableType typeVariable) =
    case find ((== typeVariable) . substitutionTypeVariable) substitutions of
      Just substitution -> substitutionType substitution
      Nothing -> VariableType typeVariable
substituteType substitutions (ApplicationType type1 type2) =
    ApplicationType
      (substituteType substitutions type1)
      (substituteType substitutions type2)
substituteType _ typ = typ

--------------------------------------------------------------------------------
-- Type inference

unify :: MonadThrow m => Type Name -> Type Name -> InferT m ()
unify t1 t2 = do
  s <- InferT (gets inferStateSubstitutions)
  u <- unifyTypes (substituteType s t1) (substituteType s t2)
  InferT
    (modify
       (\s' -> s' {inferStateSubstitutions = u @@ inferStateSubstitutions s'}))

newVariableType :: Monad m => Kind -> InferT m (Type Name)
newVariableType k =
  InferT
    (do inferState <- get
        put inferState {inferStateCounter = inferStateCounter inferState + 1}
        return
          (VariableType (TypeVariable (enumId (inferStateCounter inferState)) k)))

inferExplicitlyTypedBindingType
  :: (MonadThrow m, Show l  )
  => Map Name (Class Type Name l)
  -> [TypeSignature Type Name Name]
  -> (ExplicitlyTypedBinding Type Name l)
  -> InferT m ([Predicate Type Name], ExplicitlyTypedBinding Type Name (TypeSignature Type Name l))
inferExplicitlyTypedBindingType ce as (ExplicitlyTypedBinding l (identifier, l') sc alts) = do
  (Qualified qs t) <- freshInst sc
  (ps, alts') <- inferAltTypes ce as alts t
  s <- InferT (gets inferStateSubstitutions)
  let qs' = map (substitutePredicate s) qs
      t' = substituteType s t
      fs =
        getTypeVariablesOf
          getTypeSignatureTypeVariables
          (map (substituteTypeSignature s) as)
      gs = getTypeTypeVariables t' \\ fs
      sc' = quantify gs (Qualified qs' t')
      ps' = filter (not . entail ce qs') (map (substitutePredicate s) ps)
  (ds, rs) <- split ce fs gs ps'
  if not (sc `schemesEquivalent` sc')
    then throwM (ExplicitTypeMismatch sc sc')
    else if not (null rs)
           then throwM ContextTooWeak
           else return
                  ( ds
                  , ExplicitlyTypedBinding
                      (TypeSignature l sc)
                      (identifier, TypeSignature l' sc)
                      sc
                      alts')

-- | Are two type schemes alpha-equivalent?
schemesEquivalent :: Scheme Type Name Type ->  Scheme Type Name Type -> Bool
schemesEquivalent (Forall vs1 q1) (Forall vs2 q2) =
  length vs1 == length vs2 &&
  evalState (goQ q1 q2) (mempty,mempty)
  where
    goQ (Qualified ps1 t1) (Qualified ps2 t2) =
      (&&) <$> fmap and (sequence (zipWith goPred ps1 ps2)) <*> goType t1 t2
    goPred (IsIn x ts1) (IsIn y ts2) =
      ((x == y) &&) <$> fmap and (sequence (zipWith goType ts1 ts2))
    goType (VariableType tv1) (VariableType tv2) = do
      i <- bind fst first tv1
      j <- bind snd second tv2
      pure (i == j)
    goType (ConstructorType c1) (ConstructorType c2) = pure (c1 == c2)
    goType (ApplicationType f1 a1) (ApplicationType f2 a2) =
      (&&) <$> goType f1 f2 <*> goType a1 a2
    goType _ _ = pure False
    bind the upon tv = do
      ctx <- gets the
      case M.lookup tv ctx of
        Nothing -> do
          modify (upon (M.insert tv (M.size ctx)))
          pure (M.size ctx)
        Just j -> pure j

inferImplicitlyTypedBindingsTypes
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> [ImplicitlyTypedBinding Type Name l]
  -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], [ImplicitlyTypedBinding Type Name (TypeSignature Type Name l)])
inferImplicitlyTypedBindingsTypes ce as bs = do
  ts <- mapM (\_ -> newVariableType StarKind) bs
  let is = map (fst . implicitlyTypedBindingId) bs
      scs = map toScheme ts
      as' = zipWith (\x y -> TypeSignature x y) is scs ++ as
  pss0 <-
    sequence
      (zipWith
         (\b t -> inferAltTypes ce as' (implicitlyTypedBindingAlternatives b) t)
         bs
         ts)
  let pss = map fst pss0
      binds' = map snd pss0
  s <- InferT (gets inferStateSubstitutions)
  let ps' = map (substitutePredicate s) (concat pss)
      ts' = map (substituteType s) ts
      fs =
        getTypeVariablesOf
          getTypeSignatureTypeVariables
          (map (substituteTypeSignature s) as)
      vss = map getTypeTypeVariables ts'
      gs = foldr1' union vss \\ fs
  (ds, rs) <- split ce fs (foldr1' intersect vss) ps'
  if restrictImplicitlyTypedBindings bs
    then let gs' = gs \\ getTypeVariablesOf getPredicateTypeVariables rs
             scs' = map (quantify gs' . (Qualified [])) ts'
         in return
              ( ds ++ rs
              , zipWith (\x y -> TypeSignature x y) is scs'
              , zipWith
                  (\(ImplicitlyTypedBinding l (tid, l') _, binds'') scheme ->
                     ImplicitlyTypedBinding
                       (TypeSignature l scheme)
                       (tid, TypeSignature l' scheme)
                       binds'')
                  (zip bs binds')
                  scs')
    else let scs' = map (quantify gs . (Qualified rs)) ts'
         in return
              ( ds
              , zipWith (\x y -> TypeSignature x y) is scs'
              , zipWith
                  (\(ImplicitlyTypedBinding l (tid, l') _, binds'') scheme ->
                     ImplicitlyTypedBinding (TypeSignature l scheme) (tid,TypeSignature l' scheme) binds'')
                  (zip bs binds')
                  scs')
  where
    foldr1' f xs =
      if null xs
        then []
        else foldr1 f xs

inferBindGroupTypes
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> (BindGroup Type Name l)
  -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], BindGroup Type Name (TypeSignature Type Name l))
inferBindGroupTypes ce as (BindGroup es iss) = do
  let as' = [TypeSignature v sc | ExplicitlyTypedBinding _ (v, _) sc _alts <- es]
  (ps, as'', iss') <-
    inferSequenceTypes0 inferImplicitlyTypedBindingsTypes ce (as' ++ as) iss
  qss <- mapM (inferExplicitlyTypedBindingType ce (as'' ++ as' ++ as)) es
  return (ps ++ concat (map fst qss), as'' ++ as', BindGroup (map snd qss) iss')

inferSequenceTypes0
  :: Monad m
  => (Map Name (Class Type Name l) -> [(TypeSignature Type Name Name)] -> [bg l] -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], [bg (TypeSignature Type Name l)]))
  -> Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> [[bg l]]
  -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], [[bg (TypeSignature Type Name l)]])
inferSequenceTypes0 _ _ _ [] = return ([], [], [])
inferSequenceTypes0 ti ce as (bs:bss) = do
  (ps, as', bs') <- ti ce as bs
  (qs, as'', bss') <- inferSequenceTypes0 ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as', bs' : bss')

inferSequenceTypes
  :: Monad m
  => (Map Name (Class Type Name l) -> [(TypeSignature Type Name Name)] -> bg l -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], bg (TypeSignature Type Name l)))
  -> Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> [bg l]
  -> InferT m ([Predicate Type Name], [(TypeSignature Type Name Name)], [bg (TypeSignature Type Name l)])
inferSequenceTypes _ _ _ [] = return ([], [], [])
inferSequenceTypes ti ce as (bs:bss) = do
  (ps, as', bs') <- ti ce as bs
  (qs, as'', bss') <- inferSequenceTypes ti ce (as' ++ as) bss
  return (ps ++ qs, as'' ++ as', bs' : bss')

--------------------------------------------------------------------------------
-- Instantiation

instantiateType :: [(TypeVariable Name, Type Name)] -> Type Name -> Type Name
instantiateType ts (ApplicationType l r) =
  ApplicationType (instantiateType ts l) (instantiateType ts r)
instantiateType ts ty@(VariableType tyvar) =
  case lookup tyvar ts of
    Nothing -> ty
    Just ty' -> ty' -- TODO: possibly throw error here?
-- instantiateType ts (GenericType n) = ts !! n
instantiateType _ t = t

instantiateQualified :: [(TypeVariable Name, Type Name)] -> Qualified Type Name (Type Name) -> Qualified Type Name (Type Name)
instantiateQualified ts (Qualified ps t) =
  Qualified (map (instantiatePredicate ts) ps) (instantiateType ts t)

instantiatePredicate :: [(TypeVariable Name, Type Name)] -> Predicate Type Name -> Predicate Type Name
instantiatePredicate ts (IsIn c t) = IsIn c (map (instantiateType ts) t)

--------------------------------------------------------------------------------
-- Type variables

getTypeSignatureTypeVariables :: (TypeSignature Type Name Name) -> [TypeVariable Name]
getTypeSignatureTypeVariables = getTypeVariables where
  getTypeVariables (TypeSignature _  scheme) = getSchemeTypeVariables scheme
    where getSchemeTypeVariables (Forall _ qualified) = getQualifiedTypeVariables qualified

getQualifiedTypeVariables :: Qualified Type Name (Type Name) -> [TypeVariable Name]
getQualifiedTypeVariables = getTypeVariables
  where
    getTypeVariables (Qualified predicates t) =
      getTypeVariablesOf getPredicateTypeVariables predicates `union`
      getTypeTypeVariables t

getPredicateTypeVariables :: Predicate Type Name -> [TypeVariable Name]
getPredicateTypeVariables (IsIn _ types) = getTypeVariablesOf getTypeTypeVariables types

getTypeTypeVariables :: Type Name -> [TypeVariable Name]
getTypeTypeVariables = getTypeVariables where
  getTypeVariables (VariableType typeVariable) = [typeVariable]
  getTypeVariables (ApplicationType type1 type2) =
    getTypeVariables type1 `union` getTypeVariables type2
  getTypeVariables _ = []

getTypeVariablesOf :: (a -> [TypeVariable Name]) -> [a] -> [TypeVariable Name]
getTypeVariablesOf f = nub . concatMap f

-- | Get the kind of a type.
typeKind :: Type Name -> Kind
typeKind (ConstructorType typeConstructor) = typeConstructorKind typeConstructor
typeKind (VariableType typeVariable) = typeVariableKind typeVariable
typeKind (ApplicationType typ _) =
  case (typeKind typ) of
    (FunctionKind _ kind) -> kind
    k -> k

--------------------------------------------------------------------------------
-- GOOD NAMING CONVENInferON, UNSORTED

-- | The monomorphism restriction is invoked when one or more of the
-- entries in a list of implicitly typed bindings is simple, meaning
-- that it has an alternative with no left-hand side patterns. The
-- following function provides a way to test for this:
restrictImplicitlyTypedBindings :: [(ImplicitlyTypedBinding t Name l)] -> Bool
restrictImplicitlyTypedBindings = any simple
  where
    simple =
      any (null . alternativePatterns) . implicitlyTypedBindingAlternatives

-- | The following function calculates the list of ambiguous variables
-- and pairs each one with the list of predicates that must be
-- satisfied by any choice of a default:
ambiguities :: [TypeVariable Name] -> [Predicate Type Name] -> [Ambiguity Name]
ambiguities typeVariables predicates =
  [ Ambiguity typeVariable (filter (elem typeVariable . getPredicateTypeVariables) predicates)
  | typeVariable <- getTypeVariablesOf getPredicateTypeVariables predicates \\ typeVariables
  ]

-- | The unifyTypeVariable function is used for the special case of unifying a
-- variable u with a type t.
unifyTypeVariable :: MonadThrow m => TypeVariable Name -> Type Name -> m [Substitution Name]
unifyTypeVariable typeVariable typ
  | typ == VariableType typeVariable = return nullSubst
  | typeVariable `elem` getTypeTypeVariables typ = throwM OccursCheckFails
  | typeVariableKind typeVariable /= typeKind typ = throwM KindMismatch
  | otherwise = return [Substitution typeVariable typ]

unifyPredicates :: Predicate Type Name -> Predicate Type Name -> Maybe [Substitution Name]
unifyPredicates = lift' unifyTypeList

oneWayMatchPredicate :: Predicate Type Name -> Predicate Type Name -> Maybe [Substitution Name]
oneWayMatchPredicate = lift' oneWayMatchLists

unifyTypes :: MonadThrow m => Type Name -> Type Name -> m [Substitution Name]
unifyTypes (ApplicationType l r) (ApplicationType l' r') = do
              s1 <- unifyTypes l l'
              s2 <- unifyTypes (substituteType s1 r) (substituteType s1 r')
              return (s2 @@ s1)
unifyTypes (VariableType u) t = unifyTypeVariable u t
unifyTypes t (VariableType u) = unifyTypeVariable u t
unifyTypes (ConstructorType tc1) (ConstructorType tc2)
              | tc1 == tc2 = return nullSubst
unifyTypes a b = throwM (TypeMismatch a b)

unifyTypeList :: MonadThrow m => [Type Name] -> [Type Name] -> m [Substitution Name]
unifyTypeList (x:xs) (y:ys) = do
    s1 <- unifyTypes x y
    s2 <- unifyTypeList (map (substituteType s1) xs) (map (substituteType s1) ys)
    return (s2 @@ s1)
unifyTypeList [] [] = return nullSubst
unifyTypeList _ _ = throwM ListsDoNotUnify

oneWayMatchType :: MonadThrow m => Type Name -> Type Name -> m [Substitution Name]
oneWayMatchType (ApplicationType l r) (ApplicationType l' r') = do
  sl <- oneWayMatchType l l'
  sr <- oneWayMatchType r r'
  merge sl sr
oneWayMatchType (VariableType u) t
  | typeVariableKind u == typeKind t = return [Substitution u t]
oneWayMatchType (ConstructorType tc1) (ConstructorType tc2)
  | tc1 == tc2 = return nullSubst
oneWayMatchType _ _ = throwM TypeMismatchOneWay

oneWayMatchLists :: MonadThrow m => [Type Name] -> [Type Name] -> m [Substitution Name]
oneWayMatchLists ts ts' = do
    ss <- sequence (zipWith oneWayMatchType ts ts')
    foldM merge nullSubst ss

--------------------------------------------------------------------------------
-- Garbage

lookupName
  :: MonadThrow m
  => Name -> [(TypeSignature Type Name Name)] -> m (Scheme Type Name Type)
lookupName name cands = go name cands where
  go n [] = throwM (NotInScope cands n)
  go i ((TypeSignature i'  sc):as) =
    if i == i'
      then return sc
      else go i as

enumId :: Int -> Name
enumId n = ForallName n

inferLiteralType
  :: Monad m
  => SpecialTypes Name -> Literal -> InferT m ([Predicate Type Name], Type Name)
inferLiteralType specialTypes (CharacterLiteral _) =
  return ([], ConstructorType (specialTypesChar specialTypes))
inferLiteralType specialTypes (IntegerLiteral _) = do
  return ([], ConstructorType (specialTypesInteger specialTypes))
inferLiteralType specialTypes (StringLiteral _) =
  return ([], ConstructorType (specialTypesString specialTypes))
inferLiteralType specialTypes (RationalLiteral _) = do
  return ([], ConstructorType (specialTypesRational specialTypes))

inferPattern
  :: MonadThrow m
  => [TypeSignature Type Name Name] -> Pattern Type Name l
  -> InferT m (Pattern Type Name (TypeSignature Type Name l), [Predicate Type Name], [(TypeSignature Type Name Name)], Type Name)
inferPattern signatures = go
  where go (VariablePattern l i) = do
          v <- newVariableType StarKind
          return
            ( VariablePattern (TypeSignature l (toScheme v)) i
            , []
            , [TypeSignature i (toScheme v)]
            , v)
        go (WildcardPattern l s) = do
          v <- newVariableType StarKind
          return (WildcardPattern (TypeSignature l (toScheme v)) s, [], [], v)
        go (AsPattern l i pat) = do
          (pat', ps, as, t) <- go pat
          return (AsPattern (TypeSignature l (toScheme t)) i pat', ps, (TypeSignature i (toScheme t)) : as, t)
        go (LiteralPattern l0 l) = do
          specialTypes <- InferT (gets inferStateSpecialTypes)
          (ps, t) <- inferLiteralType specialTypes l
          return (LiteralPattern (TypeSignature l0 (toScheme t)) l, ps, [], t)
        go (ConstructorPattern l i pats) = do
          TypeSignature _ sc <- substituteConstr signatures i
          (pats', ps, as, ts) <- inferPatterns signatures pats
          t' <- newVariableType StarKind
          (Qualified qs t) <- freshInst sc
          specialTypes <- InferT (gets inferStateSpecialTypes)
          let makeArrow :: Type Name -> Type  Name -> Type  Name
              a `makeArrow` b = ApplicationType (ApplicationType (ConstructorType (specialTypesFunction specialTypes)) a) b
          unify t (foldr makeArrow t' ts)
          return (ConstructorPattern (TypeSignature l (toScheme t')) i pats',ps ++ qs, as, t')
-- inferPattern (LazyPattern pat) = inferPattern pat

substituteConstr
  :: MonadThrow m
  => [TypeSignature Type Name Name] -> Name -> m (TypeSignature Type Name Name)
substituteConstr subs i =
  case find
         (\case
            TypeSignature i' _ -> i' == i)
         subs of
    Just sig -> pure sig
    _ ->
      throwM
        (NameNotInConScope
           (filter
              (\case
                 TypeSignature (ConstructorName _ _) _ -> True
                 _ -> False)
              subs)
           i)

inferPatterns
  :: MonadThrow m
  => [TypeSignature Type Name Name] -> [Pattern Type Name l] -> InferT m ([Pattern Type Name (TypeSignature Type Name l)], [Predicate Type Name], [(TypeSignature Type Name Name)], [Type Name])
inferPatterns ss pats = do
  psasts <- mapM (inferPattern ss) pats
  let ps = concat [ps' | (_,ps', _, _) <- psasts]
      as = concat [as' | (_,_, as', _) <- psasts]
      ts = [t | (_, _, _, t) <- psasts]
      pats' = [ p | (p,_,_,_) <- psasts]
  return (pats', ps, as, ts)

predHead :: Predicate Type Name -> Name
predHead (IsIn i _) = i

lift'
  :: MonadThrow m
  => ([Type Name] -> [Type Name] -> m a) -> Predicate Type Name -> Predicate Type Name -> m a
lift' m (IsIn i ts) (IsIn i' ts')
  | i == i' = m ts ts'
  | otherwise = throwM ClassMismatch

-- lookupClassTypeVariables :: Map Name (Class Type Name l) -> Name -> [TypeVariable Name]
-- lookupClassTypeVariables ce i =
--   fromMaybe
--     []
--     (fmap classTypeVariables (M.lookup i ce))

-- lookupClassSuperclasses :: Map Name (Class Type Name l) -> Name -> [Predicate Type Name]
-- lookupClassSuperclasses ce i = maybe [] classSuperclasses (M.lookup i ce)

-- lookupClassMethods :: Map Name (Class Type Name l) -> Name -> Map Name (Type Name)
-- lookupClassMethods ce i = maybe mempty classMethods (M.lookup i ce)

-- lookupClassInstances :: Map Name (Class Type Name l) -> Name -> [Instance Type Name l]
-- lookupClassInstances ce i =
--   maybe [] classInstances (M.lookup i ce)

defined :: Maybe a -> Bool
defined (Just _) = True
defined Nothing = False


-- | Add a class to the environment. Example:
--
-- @
-- env <- addClass (Name l \"Num\") [TypeVariable (Name \"n\") StarKind] [] mempty
-- @
--
-- Throws 'ReadException' in the case of error.
addClass
  :: MonadThrow m
  => Class Type Name l
  -> Map Name (Class Type Name l)
  -> m (Map Name (Class Type Name l))
addClass (Class vs ps _ i methods) ce
  | defined (M.lookup i ce) = throwM ClassAlreadyDefined
  | any (not . defined . flip M.lookup ce . predHead) ps =
    throwM UndefinedSuperclass
  | otherwise = return (M.insert i (Class vs ps [] i methods) ce)


-- | Add an instance of a class. Example:
--
-- @
-- env <- addInstance [] (IsIn (Name \"Num\") [ConstructorType (TypeConstructor (Name \"Integer\") StarKind)]) mempty
-- @
--
-- Throws 'ReadException' in the case of error.
addInstance
  :: MonadThrow m
  => Instance Type Name l
  -> Map Name (Class Type Name l)
  -> m (Map Name (Class Type Name l))
addInstance (Instance (Forall vs (Qualified preds p@(IsIn i _))) dict) ce =
  case M.lookup i ce of
    Nothing -> throwM NoSuchClassForInstance
    Just typeClass
      | any (overlap p) qs -> throwM OverlappingInstance
      | otherwise -> return (M.insert i c ce)
      where its = classInstances typeClass
            qs = [q | Instance (Forall _ (Qualified _ q)) _ <- its]
            ps = []
            c =
              (Class
                 (classTypeVariables typeClass)
                 (classSuperclasses typeClass)
                 (Instance (Forall vs (Qualified (nub (ps ++ preds)) p)) dict :
                  its)
                 i
                 (classMethods typeClass))

overlap :: Predicate Type Name -> Predicate Type Name -> Bool
overlap p q = defined (unifyPredicates p q)

bySuper :: Map Name (Class Type Name l) -> Predicate Type Name -> [Predicate Type Name]
bySuper ce p@(IsIn i ts) = p : concat (map (bySuper ce) supers)
  where
    supers =
      map
        (substitutePredicate substitutions)
        (maybe [] classSuperclasses (M.lookup i ce))
    substitutions =
      zipWith Substitution (maybe [] classTypeVariables (M.lookup i ce)) ts

byInst
  :: Map Name (Class Type Name l)
  -> Predicate Type Name
  -> Maybe ([Predicate Type Name], Dictionary Type Name l)
byInst ce p@(IsIn i _) =
  case M.lookup i ce of
    Nothing -> throwM NoSuchClassForInstance
    Just typeClass ->
      (msum [tryInst it | it <- classInstances typeClass])
  where
    tryInst (Instance (Forall _ (Qualified ps h)) dict) = do
      (return ())
      case oneWayMatchPredicate h p of
        Just u ->
          (Just (map (substitutePredicate u) ps, dict))
        Nothing -> Nothing

entail :: Show l =>  Map Name (Class Type Name l) -> [Predicate Type Name] -> Predicate Type Name -> Bool
entail ce ps p =
  any (p `elem`) (map (bySuper ce) ps) ||
  case byInst ce p of
    Nothing -> False
    Just (qs, _) -> all (entail ce ps) qs

simplify :: ([Predicate Type Name] -> Predicate Type Name -> Bool) -> [Predicate Type Name] -> [Predicate Type Name]
simplify ent = loop []
  where
    loop rs [] = rs
    loop rs (p:ps)
      | ent (rs ++ ps) p = loop rs ps
      | otherwise = loop (p : rs) ps

reduce :: Show l => Map Name (Class Type Name l) -> [Predicate Type Name] -> [Predicate Type Name]
reduce ce = simplify (scEntail ce) . elimTauts ce

elimTauts :: Show l => Map Name (Class Type Name l) -> [Predicate Type Name] -> [Predicate Type Name]
elimTauts ce ps = [p | p <- ps, not (entail ce [] p)]

scEntail :: Map Name (Class Type Name l) -> [Predicate Type Name] -> Predicate Type Name -> Bool
scEntail ce ps p = any (p `elem`) (map (bySuper ce) ps)

quantify :: [TypeVariable Name] -> Qualified Type Name (Type Name) -> Scheme Type Name Type
quantify vs qt = Forall vs' qt
  where
    vs' = [v | v <- getQualifiedTypeVariables qt, v `elem` vs]
    {-ks = map typeVariableKind vs'-}
    {-s = zipWith Substitution vs' (map undefined {-GenericType-} [0 ..])-}

toScheme :: Type Name -> Scheme Type Name Type
toScheme t = Forall [] (Qualified [] t)

merge
  :: MonadThrow m
  => [Substitution Name] -> [Substitution Name] -> m [Substitution Name]
merge s1 s2 =
  if agree
    then return (s1 ++ s2)
    else throwM MergeFail
  where
    agree =
      all
        (\v -> substituteType s1 (VariableType v) == substituteType s2 (VariableType v))
        (map substitutionTypeVariable s1 `intersect`
         map substitutionTypeVariable s2)

inferExpressionType
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> (Expression Type Name l)
  -> InferT m ([Predicate Type Name], Type Name, Expression Type Name (TypeSignature Type Name l))
inferExpressionType ce as (ParensExpression l e) = do
  (ps, t, e') <- inferExpressionType ce as e
  pure (ps, t, ParensExpression (fmap (const l) (expressionLabel e')) e')
inferExpressionType _ as (VariableExpression l i) = do
  sc <- lookupName i as
  qualified@(Qualified ps t) <- freshInst sc
  let scheme = (Forall [] qualified)
  return (ps, t, VariableExpression (TypeSignature l scheme) i)
inferExpressionType _ _ (ConstantExpression l i) = do
  t <- newVariableType StarKind
  return ([], t, (ConstantExpression (TypeSignature l (toScheme t)) i))
inferExpressionType _ as (ConstructorExpression l i) = do
  sc <- lookupName i as
  qualified@(Qualified ps t) <- freshInst sc
  let scheme = (Forall [] qualified)
  return (ps, t, ConstructorExpression (TypeSignature l scheme) i)
inferExpressionType _ _ (LiteralExpression l0 l) = do
  specialTypes <- InferT (gets inferStateSpecialTypes)
  (ps, t) <- inferLiteralType specialTypes l
  let scheme = (Forall [] (Qualified ps t))
  return (ps, t, LiteralExpression (TypeSignature l0 scheme) l)
inferExpressionType ce as (ApplicationExpression l e f) = do
  (ps, te, e') <- inferExpressionType ce as e
  (qs, tf, f') <- inferExpressionType ce as f
  t <- newVariableType StarKind
  specialTypes <- InferT (gets inferStateSpecialTypes)
  let makeArrow :: Type Name -> Type  Name -> Type  Name
      a `makeArrow` b = ApplicationType (ApplicationType (ConstructorType(specialTypesFunction specialTypes)) a) b
  unify (tf `makeArrow` t) te
  let scheme = (Forall [] (Qualified (ps++qs) t))
  return (ps ++ qs, t, ApplicationExpression (TypeSignature l scheme) e' f')
inferExpressionType ce as (InfixExpression l x (i,op) y) = do
  (ps, ts, ApplicationExpression l' (ApplicationExpression _ (op') x') y') <-
    inferExpressionType
      ce
      as
      (ApplicationExpression l (ApplicationExpression l op x) y)
  pure (ps, ts, InfixExpression l' x' (i, op') y')
inferExpressionType ce as (LetExpression l bg e) = do
  (ps, as', bg') <- inferBindGroupTypes ce as bg
  (qs, t, e') <- inferExpressionType ce (as' ++ as) e
  let scheme = (Forall [] (Qualified (ps++qs) t))
  return (ps ++ qs, t, LetExpression (TypeSignature l scheme) bg' e')
inferExpressionType ce as (LambdaExpression l alt) = do
  (x, y, s) <- inferAltTypeForLambda ce as alt
  pure
    ( x
    , y
    , LambdaExpression
        (TypeSignature l (typeSignatureScheme (alternativeLabel s)))
        s)
inferExpressionType ce as (IfExpression l e e1 e2) = do
  (ps, t, e') <- inferExpressionType ce as e
  specialTypes <- InferT (gets inferStateSpecialTypes)
  unify t (dataTypeConstructor (specialTypesBool specialTypes))
  (ps1, t1, e1') <- inferExpressionType ce as e1
  (ps2, t2, e2') <- inferExpressionType ce as e2
  unify t1 t2
  let scheme = (Forall [] (Qualified (ps ++ ps1 ++ ps2) t1))
  return (ps ++ ps1 ++ ps2, t1, IfExpression (TypeSignature l scheme) e' e1' e2')
inferExpressionType ce as (CaseExpression l e branches) = do
  (ps0, t, e') <- inferExpressionType ce as e
  v <- newVariableType StarKind
  let tiBr (CaseAlt l' pat f) = do
        (pat', ps, as', t') <- inferPattern as pat
        unify t t'
        (qs, t'', f') <- inferExpressionType ce (as' ++ as) f
        unify v t''
        return
          (ps ++ qs, (CaseAlt (fmap (const l') (expressionLabel f')) pat' f'))
  branchs <- mapM tiBr branches
  let pss = map fst branchs
      branches' = map snd branchs
  let scheme = (Forall [] (Qualified (ps0 ++ concat pss) v))
  return
    (ps0 ++ concat pss, v, CaseExpression (TypeSignature l scheme) e' branches')

inferAltTypeForLambda
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> Alternative Type Name l
  -> InferT m ([Predicate Type Name], Type Name, Alternative Type Name (TypeSignature Type Name l))
inferAltTypeForLambda ce as alt =
  inferAltType0
    ce
    as
    (\l scheme pats ex -> Alternative (TypeSignature l scheme) pats ex)
    alt

inferAltTypeForBind
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> Alternative Type Name l
  -> InferT m ([Predicate Type Name], Type Name, Alternative Type Name (TypeSignature Type Name l))
inferAltTypeForBind ce as alt =
  inferAltType0 ce as makeAltForDecl alt

inferAltType0
  :: (Show t1, MonadThrow m)
  => Map Name (Class Type Name t1)
  -> [TypeSignature Type Name Name]
  -> (t1 -> Scheme Type Name Type -> [Pattern Type Name (TypeSignature Type Name t1)] -> Expression Type Name (TypeSignature Type Name t1) -> t)
  -> Alternative Type Name t1
  -> InferT m ([Predicate Type Name], Type Name, t)
inferAltType0 ce as makeAlt (Alternative l pats e) = do
  (pats', ps, as', ts) <- inferPatterns as pats
  (qs, t, e') <- inferExpressionType ce (as' ++ as) e
  specialTypes <- InferT (gets inferStateSpecialTypes)
  let makeArrow :: Type Name -> Type Name -> Type Name
      a `makeArrow` b = ApplicationType (ApplicationType (ConstructorType(specialTypesFunction specialTypes)) a) b
  let scheme = (Forall [] (Qualified (ps ++ qs) (foldr makeArrow t ts)))
  return (ps ++ qs, foldr makeArrow t ts, makeAlt l scheme pats' e')

-- | During parsing, we parse
-- f = \x -> x
-- as
-- f x = x
-- After type-checking, we expand the lambda out again:
--
-- f = \x -> x
--
-- But type-checked and generalized.
makeAltForDecl
  :: a
  -> Scheme Type i1 Type
  -> [Pattern Type i (TypeSignature Type i1 a)]
  -> Expression Type i (TypeSignature Type i1 a)
  -> Alternative Type i (TypeSignature Type i1 a)
makeAltForDecl l scheme pats' e' =
  if null pats'
    then Alternative (TypeSignature l scheme) pats' e'
    else Alternative
           (TypeSignature l scheme)
           []
           (LambdaExpression
              (TypeSignature l scheme)
              (Alternative (TypeSignature l scheme) pats' e'))

inferAltTypes
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l)
  -> [(TypeSignature Type Name Name)]
  -> [Alternative Type Name l]
  -> Type Name
  -> InferT m ([Predicate Type Name], [Alternative Type Name (TypeSignature Type Name l)])
inferAltTypes ce as alts t = do
  psts <- mapM (inferAltTypeForBind ce as) alts
  mapM_ (unify t) (map snd3 psts)
  return (concat (map fst3 psts), map thd3 psts)
  where snd3 (_,x,_) = x
        thd3 (_,_,x) = x
        fst3 (x,_,_) = x

split
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l) -> [TypeVariable Name] -> [TypeVariable Name] -> [Predicate Type Name] -> m ([Predicate Type Name], [Predicate Type Name])
split ce fs gs ps = do
  let ps' = reduce ce ps
      (ds, rs) = partition (all (`elem` fs) . getPredicateTypeVariables) ps'
  rs' <- defaultedPredicates ce (fs ++ gs) rs
  return (ds, rs \\ rs')

candidates :: (Show l)=> Map Name (Class Type Name l) -> Ambiguity Name -> [Type Name]
candidates ce (Ambiguity v qs) =
  [ t'
  | let is = [i | IsIn i _ <- qs]
        ts = [t | IsIn _ t <- qs]
  , all ([VariableType v] ==) ts
  , any (`elem` numClasses) is
  , all (`elem` stdClasses) is
  , t' <- [VariableType (TypeVariable (TypeName (-1) "x") StarKind)]-- classEnvironmentDefaults ce
  , all (entail ce []) [IsIn i [t'] | i <- is]
  ]
  where -- disabling these
        numClasses = [ForallName (-1)]
        stdClasses = [ForallName (-1)]


withDefaults
  :: (MonadThrow m, Show l)
  => String
  -> ([Ambiguity Name] -> [Type Name] -> a)
  -> Map Name (Class Type Name l)
  -> [TypeVariable Name]
  -> [Predicate Type Name]
  -> m a
withDefaults _label f ce vs ps
  | any null tss = throwM (AmbiguousInstance vps)
  | otherwise = do
    return (f vps (map head tss))
  where
    -- showp :: Show a => a -> String
    -- showp = \x -> "(" ++ show x ++ ")"
    vps = ambiguities vs ps
    tss = map (candidates ce) vps

defaultedPredicates
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l) -> [TypeVariable Name] -> [Predicate Type Name] -> m [Predicate Type Name]
defaultedPredicates = withDefaults "defaultedPredicates" (\vps _ -> concat (map ambiguityPredicates vps))

defaultSubst
  :: (MonadThrow m, Show l)
  => Map Name (Class Type Name l) -> [TypeVariable Name] -> [Predicate Type Name] -> m [Substitution Name]
defaultSubst = withDefaults "defaultSubst" (\vps ts -> zipWith Substitution (map ambiguityTypeVariable vps) ts)

-- extSubst
--   :: Monad m
--   => [Substitution] -> InferT m ()
-- extSubst s' =
--   InferT
--     (modify
--        (\s -> s {inferStateSubstitutions = s' @@ inferStateSubstitutions s}))

freshInst
  :: Monad m
  => Scheme Type Name Type -> InferT m (Qualified Type Name (Type Name))
freshInst (Forall ks qt) = do
  ts <- mapM (\vorig -> (vorig, ) <$> newVariableType (typeVariableKind vorig)) ks
  return (instantiateQualified ts qt)
