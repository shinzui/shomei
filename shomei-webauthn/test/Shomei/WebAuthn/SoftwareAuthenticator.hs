-- | A deliberately tiny test-only ES256 authenticator. The public private scalar (1)
-- and fixed signing nonce (2) MUST NEVER be used for real credentials. Building browser
-- wire data independently exercises production JSON/CBOR decoding as well as verification.
module Shomei.WebAuthn.SoftwareAuthenticator
  ( ResponsePolicy (..),
    goodPolicy,
    credentialBytes,
    fixtureHandle,
    registrationResponse,
    assertionResponse,
    challengeOf,
    freezeChallenge,
  )
where

import Crypto.Hash (Digest, SHA256 (..), hash)
import Crypto.Number.Serialize (i2osp, i2ospOf_)
import Crypto.PubKey.ECC.ECDSA qualified as ECDSA
import Crypto.PubKey.ECC.Prim (pointBaseMul)
import Crypto.PubKey.ECC.Types (CurveName (SEC_p256r1), Point (..), getCurveByName)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseMaybe, withObject, (.:))
import Data.Bits (shiftR)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Word (Word32, Word8)
import Shomei.Passkey.Domain (b64urlEncode)

data ResponsePolicy = ResponsePolicy
  { responseOrigin :: Text,
    responseRp :: Text,
    responseChallenge :: Maybe Text,
    responseType :: Maybe Text,
    responseFlags :: Word8,
    responseCounter :: Word32,
    responseHandle :: ByteString,
    corruptSignature :: Bool
  }

goodPolicy :: ResponsePolicy
goodPolicy = ResponsePolicy "https://localhost" "localhost" Nothing Nothing 5 1 fixtureHandle False

credentialBytes, fixtureHandle :: ByteString
credentialBytes = "test-only-es256-credential"
fixtureHandle = "test-only-user-handle"

challengeOf :: Value -> Text
challengeOf v = maybe (error "fixture options lack challenge") id (parseMaybe (withObject "options" (.: "challenge")) v)

freezeChallenge :: Value -> Value
freezeChallenge (Object o) = Object (KM.insert "challenge" (String (b64urlEncode "fixed-test-challenge-with-32-bytes")) o)
freezeChallenge _ = error "fixture options are not an object"

sha256 :: ByteString -> ByteString
sha256 bytes = convert (hash bytes :: Digest SHA256)

-- Minimal definite-length CBOR for this fixture's byte and text strings.
cbor :: Word8 -> ByteString -> ByteString
cbor major bytes = prefix <> bytes
  where
    n = BS.length bytes
    prefix
      | n < 24 = BS.singleton (major + fromIntegral n)
      | n < 256 = BS.pack [major + 24, fromIntegral n]
      | otherwise = BS.pack [major + 25, fromIntegral (n `shiftR` 8), fromIntegral n]

publicKey :: ByteString
publicKey = case pointBaseMul (getCurveByName SEC_p256r1) 1 of
  Point x y -> BS.pack [0xa5, 1, 2, 3, 0x26, 0x20, 1, 0x21] <> cbor 0x40 (i2ospOf_ 32 x) <> BS.singleton 0x22 <> cbor 0x40 (i2ospOf_ 32 y)
  PointO -> error "invalid fixture point"

authData :: Bool -> ResponsePolicy -> ByteString
authData registration p = sha256 (encodeUtf8 p.responseRp) <> BS.singleton flags <> counter <> attested
  where
    flags = p.responseFlags + if registration then 0x40 else 0
    n = p.responseCounter
    counter = BS.pack [fromIntegral (n `shiftR` bits) | bits <- [24, 16, 8, 0]]
    attested
      | registration = BS.replicate 16 0 <> BS.pack [0, fromIntegral (BS.length credentialBytes)] <> credentialBytes <> publicKey
      | otherwise = BS.empty

clientData :: Text -> Value -> ResponsePolicy -> ByteString
clientData kind options p =
  LBS.toStrict
    ( encode
        ( object
            [ "type" .= maybe kind id p.responseType,
              "challenge" .= maybe (challengeOf options) id p.responseChallenge,
              "origin" .= p.responseOrigin,
              "crossOrigin" .= False
            ]
        )
    )

registrationResponse :: Value -> ResponsePolicy -> Value
registrationResponse options p =
  object
    [ "id" .= b64urlEncode credentialBytes,
      "rawId" .= b64urlEncode credentialBytes,
      "type" .= ("public-key" :: Text),
      "response"
        .= object
          [ "clientDataJSON" .= b64urlEncode (clientData "webauthn.create" options p),
            "attestationObject" .= b64urlEncode attestation,
            "transports" .= ([] :: [Text])
          ],
      "clientExtensionResults" .= object []
    ]
  where
    attestation = BS.singleton 0xa3 <> cbor 0x60 "fmt" <> cbor 0x60 "none" <> cbor 0x60 "attStmt" <> BS.singleton 0xa0 <> cbor 0x60 "authData" <> cbor 0x40 (authData True p)

assertionResponse :: Value -> ResponsePolicy -> Value
assertionResponse options p =
  object
    [ "id" .= b64urlEncode credentialBytes,
      "rawId" .= b64urlEncode credentialBytes,
      "type" .= ("public-key" :: Text),
      "response"
        .= object
          [ "clientDataJSON" .= b64urlEncode client,
            "authenticatorData" .= b64urlEncode authenticator,
            "signature" .= b64urlEncode signature,
            "userHandle" .= b64urlEncode p.responseHandle
          ],
      "clientExtensionResults" .= object []
    ]
  where
    client = clientData "webauthn.get" options p
    authenticator = authData False p
    signature
      | p.corruptSignature = "invalid-signature"
      | otherwise = case ECDSA.signWith 2 (ECDSA.PrivateKey (getCurveByName SEC_p256r1) 1) SHA256 (authenticator <> sha256 client) of
          Just (ECDSA.Signature r s) -> der 0x30 (integer r <> integer s)
          Nothing -> error "fixture signature failed"
    integer n = let bytes = i2osp n; positive = if BS.head bytes >= 128 then BS.cons 0 bytes else bytes in der 2 positive
    der tag bytes = BS.pack [tag, fromIntegral (BS.length bytes)] <> bytes
