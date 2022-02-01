-- |Higher-level for RPC messages.

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE RecordWildCards #-}
module Network.ONCRPC.Message
  ( Call(..)
  , Reply(..)
  , ReplyException
  , replyResult
  , getReply
  , Msg(..)
  ) where

import           Control.Applicative ((<|>))
import           Control.Exception (Exception(..))
import           Control.Monad (guard)
import qualified Data.Serialize as S
import           Data.Typeable (Typeable)
import           Data.Void (Void)

import qualified Network.ONCRPC.XDR as XDR
import           Network.ONCRPC.XDR.Serial
import qualified Network.ONCRPC.Prot as RPC
import           Network.ONCRPC.Types
import           Network.ONCRPC.Exception
import           Network.ONCRPC.Auth

-- |'RPC.Call_body' with parameters
data Call a r = Call
  { callProcedure :: !(Procedure a r)
  , callCred :: !Auth
  , callVerf :: !Auth
  , callArgs :: a
  }
  deriving (Show)

splitCall :: Call a r -> (RPC.Call_body, a)
splitCall Call{ callProcedure = Procedure{..}, ..} =
  ( RPC.Call_body
    { RPC.call_body'rpcvers = RPC.rPC_VERS
    , RPC.call_body'prog = procedureProg
    , RPC.call_body'vers = procedureVers
    , RPC.call_body'proc = procedureProc
    , RPC.call_body'cred = opacifyAuth callCred
    , RPC.call_body'verf = opacifyAuth callVerf
    }
  , callArgs
  )

getCall :: XDR.XDR a => RPC.Call_body -> S.Get (Call a r)
getCall RPC.Call_body{..} = do
  guard $ call_body'rpcvers == RPC.rPC_VERS
  a <- xdrGet
  return Call
    { callProcedure = Procedure
      { procedureProg = call_body'prog
      , procedureVers = call_body'vers
      , procedureProc = call_body'proc
      }
    , callCred = unopacifyAuth call_body'cred
    , callVerf = unopacifyAuth call_body'verf
    , callArgs = a
    }

instance XDR.XDR a => XDR.XDR (Call a r) where
  xdrType _ = "call_body_args"
  xdrPut = xdrPut . splitCall
  xdrGet = getCall =<< xdrGet

-- |'RPC.Reply_body' with results
data Reply a
  = Reply
    { replyVerf :: !Auth
    , replyResults :: a
    }
  | ReplyError
    { replyVerf :: !Auth
    , replyError :: !RPC.Accepted_reply_data
    }
  | ReplyRejected
    { replyRejected :: !RPC.Rejected_reply
    }
  | ReplyFail String -- ^Missing/corrupt response
  deriving (Typeable)

instance Show a => Show (Reply a) where
  showsPrec p (Reply v r) = showParen (p > 10) $
    showString "Reply " . showsPrec 11 v . showChar ' ' . showsPrec 11 r
  showsPrec _ r = showString "RPC reply error: " . showString (se r) where
    se (Reply _ _) = "SUCCESS"
    se (ReplyError _ (RPC.Accepted_reply_data'PROG_MISMATCH l h)) = "PROG_MISMATCH(" ++ show l ++ "," ++ show h ++ ")"
    se (ReplyError _ e) = show $ RPC.accepted_reply_data'stat e
    se (ReplyRejected (RPC.Rejected_reply'RPC_MISMATCH l h)) = "RPC_MISMATCH(" ++ show l ++ "," ++ show h ++ ")"
    se (ReplyRejected (RPC.Rejected_reply'AUTH_ERROR s)) = "AUTH_ERROR(" ++ show s ++ ")"
    se (ReplyFail e) = e

instance Functor Reply where
  fmap f (Reply v r) = Reply v $ f r
  fmap _ (ReplyError v e) = ReplyError v e
  fmap _ (ReplyRejected e) = ReplyRejected e
  fmap _ (ReplyFail e) = ReplyFail e

type ReplyException = Reply Void
instance Exception ReplyException where
  toException = rpcExceptionToException
  fromException = rpcExceptionFromException

-- |The successful reply results or an error.
replyResult :: Reply a -> Either ReplyException a
replyResult (Reply _ r) = Right r
replyResult (ReplyError v e) = Left $ ReplyError v e
replyResult (ReplyRejected e) = Left $ ReplyRejected e
replyResult (ReplyFail e) = Left $ ReplyFail e

splitReply :: Reply a -> (RPC.Reply_body, Maybe a)
splitReply (Reply v r) = 
  ( RPC.Reply_body'MSG_ACCEPTED
    $ RPC.Accepted_reply (opacifyAuth v) RPC.Accepted_reply_data'SUCCESS
  , Just r
  )
splitReply (ReplyError v e) =
  ( RPC.Reply_body'MSG_ACCEPTED
    $ RPC.Accepted_reply (opacifyAuth v) e
  , Nothing
  )
splitReply (ReplyRejected r) =
  ( RPC.Reply_body'MSG_DENIED r
  , Nothing
  )
splitReply (ReplyFail e) = (error $ "splitReply ReplyFail: " ++ e, Nothing)

-- |Construct a 'Reply' based on an already-parsed 'RPC.Reply_body' and to-be-parsed results.
getReply :: XDR.XDR a => RPC.Reply_body -> S.Get (Reply a)
getReply (RPC.Reply_body'MSG_ACCEPTED (RPC.Accepted_reply v d@RPC.Accepted_reply_data'SUCCESS)) =
  Reply (unopacifyAuth v) <$> xdrGet <|> return (ReplyError (unopacifyAuth v) d)
getReply (RPC.Reply_body'MSG_ACCEPTED (RPC.Accepted_reply v e)) =
  return $ ReplyError (unopacifyAuth v) e
getReply (RPC.Reply_body'MSG_DENIED r) =
  return $ ReplyRejected r

instance XDR.XDR a => XDR.XDR (Reply a) where
  xdrType _ = "reply_body_result"
  xdrPut (ReplyFail e) = error e
  xdrPut r = do
    xdrPut b
    mapM_ xdrPut a
    where (b, a) = splitReply r
  xdrGet = getReply =<< xdrGet

-- |'RPC.Rpc_msg' with arguments or results.
data Msg a r
  = MsgCall
    { msgXID :: XID
    , msgCall :: Call a r
    }
  | MsgReply
    { msgXID :: XID
    , msgReply :: Reply r
    }
  deriving (Show)

instance (XDR.XDR a, XDR.XDR r) => XDR.XDR (Msg a r) where
  xdrType _ = "rpc_msg_content"
  xdrPut (MsgCall x c) = xdrPut (RPC.Rpc_msg x $ RPC.Rpc_msg_body'CALL b, a)
    where (b, a) = splitCall c
  xdrPut (MsgReply x r) = do
    xdrPut $ RPC.Rpc_msg x $ RPC.Rpc_msg_body'REPLY b
    mapM_ xdrPut a
    where (b, a) = splitReply r
  xdrGet = do
    RPC.Rpc_msg x b <- xdrGet
    case b of
      RPC.Rpc_msg_body'CALL c -> MsgCall x <$> getCall c
      RPC.Rpc_msg_body'REPLY r -> MsgReply x <$> getReply r
