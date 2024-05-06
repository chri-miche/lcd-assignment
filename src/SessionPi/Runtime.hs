module SessionPi.Runtime where
import Control.Exception (throw)
import Control.Concurrent (MVar, putMVar, takeMVar, forkIO, newEmptyMVar, myThreadId, forkFinally)

import SessionPi.Language
import Data.HashMap.Lazy (HashMap, insert, (!?), empty)
import Data.Maybe (fromJust)
import Text.Printf (printf)

data Channel = Channel (MVar Val) (MVar ())

send :: Channel -> Val -> IO ()
send (Channel var idle) val = do
    takeMVar idle       -- waits until the other end is ready to receive
    putMVar var val

receive :: Channel -> IO Val
receive (Channel var idle) = do
    putMVar idle ()     -- signals the other end tha it is ready to receive
                        -- this means that if another process is awaiting to read, this thread will wait for a free channel
    takeMVar var

run :: Proc -> IO ()
run =
    let ?channels = empty
        ?variables = empty
     in run'

type ProcIO a = (?channels :: HashMap String Channel, ?variables :: HashMap String Val) => IO a

run' :: Proc -> ProcIO ()
run' Nil = do
    logInfo "STOP"
    return ()

run' (Brn g p1 p2) = do
    logInfo (printf "BRANCHING %s" (show g))
    cond <- unlit <$> eval g
    logInfo (printf "BRANCHING Evaluated to %s" (show cond))
    if cond
        then run' p1
        else run' p2

run' (Par p1 p2) = do
    logInfo "FORK"
    end1 <- newEmptyMVar
    end2 <- newEmptyMVar
    pid1 <- forkFinally (run' p1) (\_ -> putMVar end1 ())
    pid2 <- forkFinally (run' p2) (\_ -> putMVar end2 ())
    logInfo (printf "FORK processes with id %s and %s" (show pid1) (show pid2))
    takeMVar end1
    takeMVar end2
    return ()

run' (Snd x v p) = do
    logInfo (printf "SENDING value %s over channel %s" (show v) x)
    chan <- channel x
    val <- eval v
    logInfo (printf "SENDING value %s" (show val))
    chan `send` val
    logInfo "VALUE SENT"
    run' p
run' (Rec x y p) = do
    logInfo (printf "RECEIVING value %s over channel %s" y x)
    chan <- channel x
    val <- receive chan
    logInfo (printf "RECEIVED value %s" (show val))
    let ?variables = insert y val ?variables in run' p
run' (Bnd x y p) = do
    logInfo (printf "BINDING channel ends %s and %s" x y)
    var <- newEmptyMVar
    lock <- newEmptyMVar
    let chan = Channel var lock
    let ?channels = insert x chan $ insert y chan ?channels in run' p

channel :: String -> ProcIO Channel
channel x = case ?channels !? x of
        Just chan -> return chan
        Nothing   -> throw $ userError (printf "Channel %s is undefined" x)

eval :: Val -> ProcIO Val
eval = \case
        Var x -> case ?variables !? x of
                Just v  -> return v
                Nothing -> throw $ userError (printf "Variable %s is undefined" x)
        val   -> return val

logInfo :: String -> ProcIO ()
logInfo s = do
    pid <- myThreadId
    printf "%s: [%s]\n" (show pid) s



