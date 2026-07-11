{-# LANGUAGE RankNTypes #-}

-- | Everything en-specific for the embedded demo, so "EmbeddedEn.App" reads like the
-- @embedded-servant-app@ example plus a handful of authorization lines.
--
-- __The one coupling between the two projects__ is 'subjectForUser': a Shōmei 'AuthUser'
-- becomes an en 'Subject'. Get that mapping wrong and en silently denies everything — see
-- its Haddock.
--
-- __Why this example consumes @en-core@ and reproduces the guard, rather than importing
-- @en-servant@'s 'En.Servant.Authorize.requirePermission'.__ @en-servant@'s /library/
-- depends on @openapi-hs@, @servant-openapi-hs@, @en-postgres@, and @en-biscuit@ (which
-- pulls @biscuit-haskell@). Shōmei already pins @openapi-hs@ at a different commit, and two
-- git source pins for one repository cannot coexist in a single cabal plan. @en-core@, by
-- contrast, has no en-package dependencies and no openapi/biscuit/hasql dependencies (only
-- effectful/containers/text/time), so it drops into Shōmei's existing build plan with zero
-- new external pins. 'requireProjectPermission' below is a faithful, ~20-line copy of
-- @en-servant@'s fail-closed guard, built directly over 'En.Check.check' — the call shape,
-- the subject mapping, and the fail-closed 403 are identical. A production host whose build
-- does not hit that openapi pin conflict should prefer @en-servant@'s guard; see
-- @docs/user/authorization.md@.
module EmbeddedEn.Authz
  ( -- * The identity-mapping convention
    subjectForUser,

    -- * The demo schema
    projectSchema,
    compiledProjectSchema,
    projectRef,
    grantTupleFor,

    -- * The en environment and interpreters
    EnEffects,
    EnEnv (..),
    mkEnEnv,
    runTupleStoreIORef,
    runConsistencyStoreLocal,

    -- * The fail-closed guard and the demo write path
    requireProjectPermission,
    grantRelation,
  )
where

import Control.Monad.IO.Class (liftIO)
import Data.IORef (IORef, readIORef, writeIORef)
import Data.List (find, partition)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret_)
import Effectful.Error.Static qualified as Err
import Servant (Handler, ServerError, err403, err503, errBody, errHeaders, throwError)

import En.Check (CheckDecision (..), CheckOutcome (..), check)
import En.Conformance.Kikan qualified as Kikan
import En.Effect.ConsistencyStore
  ( ConsistencyStore (..),
    ResolvedConsistency (..),
    TokenMetadata (TokenMetadata),
  )
import En.Effect.TupleStore
  ( ChangeKind (..),
    ChangePage (..),
    TupleChange (..),
    TuplePage (..),
    TupleRow (..),
    TupleStore (..),
    TupleWriteRequest (..),
    UsersetQuery (..),
    renderPrecondition,
    writeTuples,
  )
import En.Error (EnError (..))
import En.Reachability (ReachabilityGraph, compileSchema)
import En.Revision
  ( Consistency (..),
    ConsistencyToken (..),
    DatastoreId (..),
    Revision (..),
    SchemaHash (..),
  )
import En.Schema (ObjectType (..), RelationName (..), Schema)
import En.Schema.Builder qualified as Schema
import En.Tuple (CaveatContext (..), ObjectRef (..), Subject (..), Tuple (..))

import Shomei.Id (idText)
import Shomei.Servant.Auth (AuthUser (..))

-- | THE identity-mapping convention: an en subject is the TypeID text of the Shōmei user id
-- — the same string Shōmei signs into the JWT @sub@ claim — NEVER the bare UUID. en compares
-- object ids by string equality; mixing forms silently denies. (Shōmei's audit output shows
-- bare UUIDs — do not paste those into tuples.)
subjectForUser :: AuthUser -> Subject
subjectForUser u =
  SubjectId (ObjectRef {objectType = ObjectType "user", objectId = idText u.authUserId})

-- | The demo authorization model, authored with "En.Schema.Builder" exactly as
-- @En.Example.Host.exampleSchema@ does: a @project@ has @viewer@ and @editor@ relations;
-- @view@ is the union of the two (an editor can read), @edit@ requires @editor@.
--
-- A malformed fixture schema is a programming error, so this crashes at load — en-example
-- does the same.
projectSchema :: Schema
projectSchema =
  either (error . ("invalid embedded-en schema fixture: " <>) . show) id $ do
    userObject <- Schema.object "user" []
    projectObject <-
      Schema.object
        "project"
        [ Schema.relation "viewer" [Schema.subject "user"] Schema.this,
          Schema.relation "editor" [Schema.subject "user"] Schema.this,
          Schema.permission "view" (Schema.anyOf (Schema.computed "viewer") [Schema.computed "editor"]),
          Schema.permission "edit" (Schema.computed "editor")
        ]
    Schema.build [userObject, projectObject]

-- | 'projectSchema' compiled to the reachability graph the engine evaluates against.
-- Compiled once for the process; a compile failure is a programming error, so this crashes
-- at load too.
compiledProjectSchema :: ReachabilityGraph
compiledProjectSchema =
  either (error . ("embedded-en schema failed to compile: " <>) . show) id (compileSchema projectSchema)

-- | The en object for a project id: @project:\<id\>@.
projectRef :: Text -> ObjectRef
projectRef pid = ObjectRef {objectType = ObjectType "project", objectId = pid}

-- | The relation tuple granting @subject@ the given relation on @project:\<id\>@.
grantTupleFor :: Subject -> Text -> RelationName -> Tuple
grantTupleFor subject pid rel =
  Tuple {object = projectRef pid, relation = rel, subject = subject, caveat = Nothing}

-- | The engine effect stack this host runs en under. No @Database@: the store is in-memory
-- (an 'IORef'), which is what keeps this example free of a second database. See
-- 'runTupleStoreIORef' for why the 'IORef' lives outside the per-request run.
type EnEffects = '[ConsistencyStore, TupleStore, Err.Error EnError, IOE]

-- | The minimal en environment for the demo. Not @en-servant@'s 'En.Servant.Seam.Env'
-- (which the example does not depend on): just the engine runner and the compiled graph,
-- which is all 'requireProjectPermission' and 'grantRelation' need.
data EnEnv = EnEnv
  { -- | Run one engine action to completion, surfacing an engine failure as a value. The
    -- 'IORef' the interpreters read is captured in this closure, so it outlives any single
    -- run — that is what makes a grant written by one request visible to the next.
    runEn :: forall a. Eff EnEffects a -> IO (Either EnError a),
    -- | The compiled model every check evaluates against.
    graph :: ReachabilityGraph
  }

-- | Build an 'EnEnv' over a shared tuple 'IORef'. All requests share the one 'IORef', so the
-- demo's "grant a tuple, then a later request sees 200" story works across requests — an
-- 'Effectful.State.Static.Local' store (as @En.Conformance.Kikan@ uses) would reset to the
-- seed on every run.
mkEnEnv :: IORef [Tuple] -> EnEnv
mkEnEnv tuples =
  EnEnv
    { runEn = runEff . Err.runErrorNoCallStack . runTupleStoreIORef tuples . runConsistencyStoreLocal,
      graph = compiledProjectSchema
    }

-- | A write-supporting in-memory 'TupleStore' over a shared 'IORef', modeled on
-- @En.Conformance.Kikan.runTupleStoreInMemory@ but backed by an 'IORef' rather than
-- 'Effectful.State.Static.Local' so its state survives across @runEn@ calls. Reads filter
-- the list; 'ApplyTupleWrites' applies deletes-then-writes with the same touch semantics the
-- PostgreSQL store implements; every mutation mints a fresh 'ConsistencyToken'.
--
-- NOT for production: authorization data must survive restarts and agree across instances,
-- and en's consistency guarantees are grounded in PostgreSQL snapshot machinery an 'IORef'
-- only pretends to satisfy. Embed @en-postgres@ or call a standalone @en-server@ instead;
-- see the README.
runTupleStoreIORef ::
  (IOE :> es, Err.Error EnError :> es) =>
  IORef [Tuple] ->
  Eff (TupleStore : es) a ->
  Eff es a
runTupleStoreIORef ref = interpret_ \case
  ReadObjectRelation _ object relation limit cursor -> do
    tuples <- liftIO (readIORef ref)
    pure (Kikan.pageTuples limit cursor [t | t <- tuples, t.object == object, t.relation == relation])
  ReadStartingWithUser _ (UsersetQuery {queryType, queryRelation, querySubjects, queryLimit, queryCursor}) -> do
    tuples <- liftIO (readIORef ref)
    pure
      ( Kikan.pageTuples
          queryLimit
          queryCursor
          [ t
          | t <- tuples,
            t.object.objectType == queryType,
            t.relation == queryRelation,
            t.subject `elem` querySubjects
          ]
      )
  ReadAllTuples _ limit cursor -> do
    tuples <- liftIO (readIORef ref)
    pure (Kikan.pageTuples limit cursor tuples)
  ReadRelationships _ relationshipFilter limit cursor -> do
    tuples <- liftIO (readIORef ref)
    pure (Kikan.pageTuples limit cursor (filter (Kikan.matchesRelationshipFilter relationshipFilter) tuples))
  CountRelationships _ relationshipFilter -> do
    tuples <- liftIO (readIORef ref)
    pure (fromIntegral (length (filter (Kikan.matchesRelationshipFilter relationshipFilter) tuples)))
  DeleteRelationships relationshipFilter -> do
    tuples <- liftIO (readIORef ref)
    let (retired, kept) = partition (Kikan.matchesRelationshipFilter relationshipFilter) tuples
    liftIO (writeIORef ref kept)
    pure (fromIntegral (length retired), ConsistencyToken "embedded-en-write")
  ReadChanges _ _ relationshipFilter limit cursor -> do
    tuples <- liftIO (readIORef ref)
    let matching = maybe tuples (\requested -> filter (Kikan.matchesRelationshipFilter requested) tuples) relationshipFilter
        TuplePage {rows = changedRows, state = pageState} = Kikan.pageTuples limit cursor matching
    pure
      ChangePage
        { changes =
            [ TupleChange {kind = ChangeTouch, tuple = rowTuple, rowId = rowRowId}
            | TupleRow {tuple = rowTuple, rowId = rowRowId} <- changedRows
            ],
          state = pageState
        }
  ProbeTuples _ object relation subjects -> do
    tuples <- liftIO (readIORef ref)
    pure
      [ Kikan.tupleRow index t
      | (index, t) <- zip [1 ..] tuples,
        t.object == object,
        t.relation == relation,
        t.subject `elem` subjects
      ]
  -- Pattern-match the request into concrete '[Precondition]'/'[Tuple]' bindings rather than
  -- reaching for @request.writes@ etc.: OverloadedRecordDot on a 'NoFieldSelectors' record
  -- leaves the field type as @t Tuple@ under 'foldl''/'find', which cannot be solved.
  ApplyTupleWrites (TupleWriteRequest {preconditions, writes, deletes}) -> do
    tuples <- liftIO (readIORef ref)
    case find (not . Kikan.preconditionHolds tuples) preconditions of
      Just failed ->
        Err.throwError (WritePreconditionFailed (renderPrecondition failed))
      Nothing -> do
        let afterDeletes = foldl' (flip Kikan.deleteTupleByKey) tuples deletes
            afterWrites = foldl' (flip Kikan.touchTuple) afterDeletes writes
        liftIO (writeIORef ref afterWrites)
        pure (ConsistencyToken "embedded-en-write")
  HeadRevision -> pure Kikan.testRevision
  OptimizedRevision -> pure Kikan.testRevision
  OldestRetainedXid -> pure 0
  AdvanceGcHorizon -> pure 0
  ReapDeletedTuples _ -> pure 0

-- | The permissive local consistency store, a copy of @En.Example.Host.runConsistencyStoreInMemory@:
-- it accepts every token and resolves every consistency level to one fixed revision. Adequate
-- because the 'IORef' store keeps no revisions — every read sees the current state, so
-- @MinimizeLatency@ observes a write the moment it lands.
runConsistencyStoreLocal :: Eff (ConsistencyStore : es) a -> Eff es a
runConsistencyStoreLocal =
  interpret_ \case
    DecodeToken token ->
      pure (TokenMetadata token Kikan.testRevision (DatastoreId "embedded-en") (SchemaHash "schema") Nothing)
    ValidateToken _ ->
      pure ()
    ResolveConsistency consistency ->
      pure ResolvedConsistency {consistency, revision = Kikan.testRevision}
    MintToken revision ->
      pure (ConsistencyToken ("embedded-en:" <> revision.revisionEncoding))

-- | The fail-closed authorization guard, a faithful copy of
-- @En.Servant.Authorize.requirePermission@ built directly over 'En.Check.check':
--
-- * 'Allowed' returns @()@ — the handler proceeds.
-- * 'Denied' /and/ 'Conditional' throw @403@ (fail closed — an unresolved caveat denies).
-- * An engine error throws @503@ (the authorization backend is impaired; the token was
--   never judged invalid). @en-servant@ maps store outages to @503@ the same way.
requireProjectPermission :: EnEnv -> Subject -> RelationName -> ObjectRef -> Handler ()
requireProjectPermission env subject relation object = do
  -- 'runEn' is a rank-2 field (@forall a. …@), so it must be applied as a function —
  -- OverloadedRecordDot (@env.runEn@) goes through 'HasField', which cannot represent a
  -- polymorphic field type.
  result <- liftIO (runEn env (check (graph env) MinimizeLatency emptyContext subject relation object))
  case result of
    Right outcome ->
      case outcome.decision of
        Allowed -> pure ()
        Denied -> throwError permissionDenied
        Conditional _ -> throwError permissionDenied
    Left _ -> throwError backendUnavailable

-- | The demo write path: grant @subject@ the given relation on @project:\<id\>@ through en's
-- real write effect, returning the store's 'ConsistencyToken'. In production, tuple writes
-- are the host's (or @en-server@'s) job at its own trust boundary; a route letting callers
-- grant /themselves/ @editor@ exists here only so the transcript can flip 403→200 in one
-- process. The returned token is what a real host would feed into @AtLeastAsFresh@ for its
-- next check.
grantRelation :: EnEnv -> Subject -> Text -> RelationName -> IO (Either EnError ConsistencyToken)
grantRelation env subject pid rel =
  runEn env (writeTuples [grantTupleFor subject pid rel])

emptyContext :: CaveatContext
emptyContext = CaveatContext Map.empty

permissionDenied :: ServerError
permissionDenied =
  err403
    { errBody = "{\"code\":\"permission_denied\",\"message\":\"permission denied\"}",
      errHeaders = [("Content-Type", "application/json")]
    }

backendUnavailable :: ServerError
backendUnavailable =
  err503
    { errBody = "{\"code\":\"authorization_backend_unavailable\",\"message\":\"the authorization backend failed; retry later\"}",
      errHeaders = [("Content-Type", "application/json")]
    }
