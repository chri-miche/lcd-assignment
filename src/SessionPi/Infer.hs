module SessionPi.Infer where

import SessionPi.Syntax
    ( SpiType(..),
      Pretype(..),
      Qualifier(..),
      Val(..),
      Proc(..),
      argument,
      thenProcess )
import SessionPi.Types ( Claim )

import Algebra.Lattice (Lattice ((\/), (/\)), BoundedMeetSemiLattice (top), BoundedJoinSemiLattice (bottom), BoundedLattice)

import Data.Maybe (fromMaybe)
import qualified Data.Map as M

class (BoundedLattice (AbstractDomain c)) => Abstraction c where
    type AbstractDomain c
    -- abstract semantics
    sigma :: c -> AbstractDomain c

data AQual where
    AnyQual :: AQual
    OnlyUnr :: AQual
    deriving (Eq, Show)

sampleQualifier :: AQual -> Qualifier
sampleQualifier AnyQual = Lin
sampleQualifier OnlyUnr = Un

instance Lattice AQual where
    (\/) :: AQual -> AQual -> AQual
    OnlyUnr \/ OnlyUnr = OnlyUnr
    _ \/ _             = AnyQual

    (/\) :: AQual -> AQual -> AQual
    AnyQual /\ AnyQual = AnyQual
    _ /\ _             = OnlyUnr

instance BoundedMeetSemiLattice AQual where
    top :: AQual
    top = AnyQual

instance BoundedJoinSemiLattice AQual where
    bottom :: AQual
    bottom = OnlyUnr

instance Abstraction Qualifier where
    type AbstractDomain Qualifier = AQual
    sigma :: Qualifier -> AbstractDomain Qualifier
    sigma Un  = OnlyUnr
    sigma Lin = AnyQual

data AAct where
    TopAct :: AAct
    ASend :: AAct
    ARecv :: AAct
    BotAct :: AAct
    deriving (Eq, Show)

sampleAction :: AAct -> Either [String] (SpiType -> SpiType -> Pretype)
sampleAction TopAct = sampleAction ASend
sampleAction ASend = return Sending
sampleAction ARecv = return Receiving
sampleAction BotAct = Left ["Sampled bottom action"]

aDualAction :: AAct -> AAct
aDualAction ASend = ARecv
aDualAction ARecv = ASend
aDualAction a = a

instance Lattice AAct where
    (\/) :: AAct -> AAct -> AAct
    a \/ b      | a == b = a
    TopAct \/ _ = TopAct
    BotAct \/ a = a
    _ \/ TopAct = TopAct
    a \/ BotAct = a
    _ \/ _      = TopAct

    (/\) :: AAct -> AAct -> AAct
    a /\ b      | a == b = a
    TopAct /\ a = a
    BotAct /\ _ = BotAct
    a /\ TopAct = a
    _ /\ BotAct = BotAct
    _ /\ _      = BotAct

instance BoundedMeetSemiLattice AAct where
    top :: AAct
    top = TopAct

instance BoundedJoinSemiLattice AAct where
    bottom :: AAct
    bottom = BotAct

instance Abstraction Pretype where
    type AbstractDomain Pretype = AAct
    sigma :: Pretype -> AbstractDomain Pretype
    sigma (Sending {})   = ASend
    sigma (Receiving {}) = ARecv

data AType where
    TopType :: AType
    ABool :: AType
    AProc :: AType
    AEnd :: AType
    NonLinear :: AType
    Channel :: AQual -> AAct -> AType -> AType -> AType
    BotType :: AType
    deriving (Eq, Show)

sample :: AType -> Either [String] SpiType
sample TopType = sample AProc
sample ABool = Right Boolean
sample AProc = sample NonLinear
sample NonLinear = sample AEnd
sample AEnd = Right End
sample BotType = Left ["Sample bottom abstract type"]
sample (Channel AnyQual a v p) = do
    sa <- sampleAction a
    sv <- sample v
    sp <- sample p
    return (Qualified Lin (sa sv sp))
sample p@(Channel OnlyUnr _ _ q) = case q /\ p of
    (Channel OnlyUnr a v _) -> do
        sa <- sampleAction a
        sv <- sample v
        return (Recursive "x" (Qualified Un (sa sv (TypeVar "x"))))
    _ -> Left ["Could not infer an useful type from " ++ show p ++ ". Please consider adding type annotations"]


aDualType :: AType -> AType
aDualType ABool = BotType -- no type is dual of boolean
aDualType (Channel q a v p) = Channel q (aDualAction a) v (aDualType p)
aDualType t = t

instance Lattice AType where
    (\/) :: AType -> AType -> AType
    a \/ b       | a == b = a
    TopType \/ _ = TopType
    BotType \/ a = a
    _ \/ TopType = TopType
    a \/ BotType = a
    ABool \/ _   = TopType
    _ \/ ABool   = TopType
    (Channel q1 a1 v1 p1) \/ (Channel q2 a2 v2 p2) = Channel (q1 \/ q2) (a1 \/ a2) (v1 \/ v2) (p1 \/ p2)
    p \/ (Channel OnlyUnr _ _ _) | p == AEnd || p == NonLinear = NonLinear
    (Channel OnlyUnr _ _ _) \/ p | p == AEnd || p == NonLinear = NonLinear
    _ \/ _ = AProc

    (/\) :: AType -> AType -> AType
    a /\ b       | a == b = a
    TopType /\ a = a
    BotType /\ _ = BotType
    a /\ TopType = a
    _ /\ BotType = BotType
    ABool /\ _   = BotType
    _ /\ ABool   = BotType
    (Channel q1 a1 v1 p1) /\ (Channel q2 a2 v2 p2) = Channel (q1 /\ q2) (a1 /\ a2) (v1 /\ v2) (p1 /\ p2)
    AProc /\ p = p
    p /\ AProc = p
    NonLinear /\ (Channel _ a v p) = Channel OnlyUnr a v p
    (Channel _ a v p) /\ NonLinear = Channel OnlyUnr a v p
    NonLinear /\ AEnd = AEnd
    AEnd /\ NonLinear = AEnd
    _ /\ _ = BotType

instance BoundedMeetSemiLattice AType where
    top :: AType
    top = TopType

instance BoundedJoinSemiLattice AType where
    bottom :: AType
    bottom = BotType

instance Abstraction Val where
    type AbstractDomain Val = AContext -> AType
    sigma :: Val -> AContext -> AType
    sigma (Var x) = get x
    sigma _ = const ABool

instance Abstraction SpiType where
    type AbstractDomain SpiType = AType
    sigma :: SpiType -> AbstractDomain SpiType
    sigma End     = AEnd
    sigma Boolean = ABool
    sigma (Qualified q pretype) = Channel (sigma q) (sigma pretype) (sigma v) (sigma p)
        where
            v = argument pretype
            p = thenProcess pretype
    sigma (TypeVar _) = TopType
    sigma (Recursive _ t) = sigma t


type AContext = M.Map String AType

get :: String -> AContext -> AType
get x = fromMaybe TopType . M.lookup x

merge :: AContext -> AContext -> AContext
merge = M.unionWith (/\)

class Inferrable a where
    deduce :: a -> AContext -> AContext
    infer :: a -> AContext
    infer x = deduce x M.empty

instance Inferrable Claim where
    deduce :: Claim -> AContext -> AContext
    deduce (Lit _, _) ctx = ctx
    deduce (Var x, t) ctx = ctx `merge` M.singleton x (sigma t)

instance Inferrable Proc where
    deduce :: Proc -> AContext -> AContext
    deduce Nil ctx = ctx
    deduce (Snd x v p) ctx =
        let ctx' = deduce p (M.delete x $ inferCommunication x v ctx)
            atp = fromMaybe NonLinear (M.lookup x ctx')
            atv = sigma v ctx'
            atx = Channel AnyQual ASend atv atp
         in M.insert x atx ctx'
    deduce (Rec q x y p) ctx =
        let ctx' = deduce p (M.delete x 
                            $ inferCommunication x (Var y) 
                            $ M.delete y ctx)
            atp = fromMaybe NonLinear (M.lookup x ctx')
            aty = fromMaybe AProc (M.lookup y ctx')
            atx = Channel (sigma q) ARecv aty atp
         in M.insert x atx $ M.delete y ctx'
    deduce (Bnd (x1, t1) (x2, t2) p) ctx =
        let at1 = maybe TopType sigma t1
            at2 = maybe TopType sigma t2
            shadow = M.insert x1 at1 . M.insert x2 at2
            ctx' = lfpFrom (shadow ctx) (dualNarrow x1 x2 . deduce p)
         in M.delete x1 $ M.delete x2 ctx'
    deduce (Brn g p1 p2) ctx =
        let ctxg = deduce (g, Boolean) ctx
            ctx1 = deduce p1 ctxg
            ctx2 = deduce p2 ctxg
         in ctx1 `merge` ctx2
    deduce (Par p1 p2) ctx =
        let ctxWithUnr = M.unionWith parJoin (infer p1) (infer p2)
            -- questo serve solo per applicare OnlyUnr ai processi che appaiono sia a destra che a sinistra
            -- funziona sotto l'assunzione che infer p `less precise than` deduce p ctx
            ctx1 = deduce p1 ctx
            ctx2 = deduce p2 ctx
         in ctx `merge` ctx1 `merge` ctx2 `merge` ctxWithUnr

inferCommunication :: String -> Val -> AContext -> AContext
inferCommunication _ (Lit _) ctx = ctx
inferCommunication c (Var v) ctx = ctx `merge`
    M.fromList [(v, tv)]
    where
        tv = case get c ctx of
            Channel _ _ at _ -> at
            _ -> TopType

parJoin :: AType -> AType -> AType
parJoin (Channel _ a1 v1 p1) (Channel _ a2 v2 p2) = Channel OnlyUnr (a1 /\ a2) (v1 /\ v2) (p1 /\ p2)
-- parJoin AEnd c@(Channel {}) = c
-- parJoin c@(Channel {}) AEnd = c
parJoin t1 t2 = t1 /\ t2

dualNarrow :: String -> String -> AContext -> AContext
dualNarrow x y = do
    tx <- get x
    ty <- get y
    M.insert x (tx /\ aDualType ty) . M.insert y (ty /\ aDualType tx)

lfpFrom :: (Eq a) => a -> (a -> a) -> a
lfpFrom x fn | fn x == x = x
             | otherwise = lfpFrom (fn x) fn

