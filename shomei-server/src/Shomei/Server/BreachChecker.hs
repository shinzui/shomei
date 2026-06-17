{-# LANGUAGE DataKinds #-}

{- | EP-3 production interpreter for 'PasswordBreachChecker': a HIBP Pwned Passwords range
query using k-anonymity. Only the 5-char SHA-1 prefix leaves the process; the full hash and the
plaintext never go on the wire. Constructed once when the effect stack is assembled, from a
shared TLS 'Manager' and a fixed per-call timeout (the EP-1 @breachCheckTimeoutMs@ policy).

Any transport error or timeout is caught and reported as 'BreachCheckUnavailable', leaving the
fail-open / fail-closed decision to 'Shomei.Workflow.Breach.enforceBreachPolicy'.
-}
module Shomei.Server.BreachChecker (runPasswordBreachCheckerHibp) where

import Control.Exception (SomeException, try)
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE

import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Dispatch.Dynamic (interpret_)

import Network.HTTP.Client (
    Manager,
    Request (..),
    httpLbs,
    parseRequest,
    responseBody,
    responseTimeoutMicro,
 )
import Network.HTTP.Types.Header (hUserAgent)

import Shomei.Effect.PasswordBreachChecker (
    BreachResult (..),
    PasswordBreachChecker (..),
    parseHibpResponse,
    sha1PrefixSuffix,
 )

{- | Build the interpreter from a shared TLS manager and a timeout in milliseconds (pass
@cfg.passwordPolicy.breachCheckTimeoutMs@ at assembly time).
-}
runPasswordBreachCheckerHibp ::
    (IOE :> es) => Manager -> Int -> Eff (PasswordBreachChecker : es) a -> Eff es a
runPasswordBreachCheckerHibp mgr timeoutMs = interpret_ \case
    CheckPasswordBreached plain -> liftIO do
        let (prefix, suffix) = sha1PrefixSuffix plain
        result <- try (queryRange mgr timeoutMs prefix) :: IO (Either SomeException Text)
        pure case result of
            Left _ -> BreachCheckUnavailable
            Right body -> if parseHibpResponse body suffix then Breached else NotBreached

-- | Fetch the HIBP range bucket for a 5-char prefix as decoded text. Throws on transport
-- errors and timeouts (caught by the interpreter above).
queryRange :: Manager -> Int -> Text -> IO Text
queryRange mgr timeoutMs prefix = do
    base <- parseRequest ("https://api.pwnedpasswords.com/range/" <> Text.unpack prefix)
    let req =
            base
                { requestHeaders =
                    ("Add-Padding", "true")
                        : (hUserAgent, "shomei")
                        : requestHeaders base
                , responseTimeout = responseTimeoutMicro (timeoutMs * 1000)
                }
    resp <- httpLbs req mgr
    pure (TE.decodeUtf8 (LBS.toStrict (responseBody resp)))
