--  This Source Code Form is subject to the terms of the Mozilla Public
--  License, v. 2.0. If a copy of the MPL was not distributed with this
--  file, You can obtain one at http://mozilla.org/MPL/2.0/.

{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Kupo.App.Database
    ( -- * Database DSL
      Database (..)
    , DBTransaction

      -- ** Queries
      -- *** Inputs
    , deleteInputsQry
    , markInputsQry
    , pruneInputsQry
    , foldInputsQry
      -- *** Checkpoints
    , listCheckpointsQry
    , listAncestorQry
      -- *** Binary Data
    , getBinaryDataQry
    , pruneBinaryDataQry
      -- *** Scripts
    , getScriptQry
      -- *** Rollback
    , selectMaxCheckpointQry
    , rollbackQry1
    , rollbackQry2
    , rollbackQry3

      -- * Setup
    , createShortLivedConnection
    , withLongLivedConnection
    , Connection
    , ConnectionType (..)
    , DatabaseFile (..)

      -- ** Lock
    , DBLock
    , newLock

      -- * Tracer
    , TraceDatabase (..)
    ) where

import Kupo.Prelude

import Control.Exception
    ( mask
    , onException
    , throwIO
    )
import Control.Monad.Class.MonadSTM
    ( MonadSTM (..)
    )
import Control.Monad.Class.MonadThrow
    ( bracket_
    , catch
    )
import Control.Monad.Class.MonadTimer
    ( threadDelay
    )
import Control.Tracer
    ( Tracer
    , traceWith
    )
import Data.FileEmbed
    ( embedFile
    )
import Data.Severity
    ( HasSeverityAnnotation (..)
    , Severity (..)
    )
import Database.SQLite.Simple
    ( Connection
    , Error (..)
    , Only (..)
    , Query (..)
    , SQLData (..)
    , SQLError (..)
    , ToRow (..)
    , changes
    , execute
    , execute_
    , fold_
    , nextRow
    , query_
    , withConnection
    , withStatement
    )
import GHC.TypeLits
    ( KnownSymbol
    , symbolVal
    )
import Kupo.Control.MonadTime
    ( DiffTime
    )
import Kupo.Data.Cardano
    ( BinaryData
    , DatumHash
    , Point
    , Script
    , ScriptHash
    , SlotNo (..)
    )
import Kupo.Data.Configuration
    ( DeferIndexesInstallation (..)
    , LongestRollback (..)
    )
import Kupo.Data.Database
    ( SortDirection (..)
    , patternToSql
    , statusFlagToSql
    )
import Kupo.Data.Http.StatusFlag
    ( StatusFlag
    )
import Kupo.Data.Pattern
    ( Pattern
    , Result
    , patternToText
    )
import Numeric
    ( Floating (..)
    )

import qualified Data.Text as T
import qualified Database.SQLite.Simple as Sqlite
import qualified Kupo.Data.Database as DB

data Database (m :: Type -> Type) = Database
    { insertInputs
        :: [DB.Input]
        -> DBTransaction m ()

    , deleteInputs
        :: Set Pattern
        -> DBTransaction m Int

    , markInputs
        :: SlotNo
        -> Set Pattern
        -> DBTransaction m Int

    , pruneInputs
        :: DBTransaction m Int

    , foldInputs
        :: Pattern
        -> StatusFlag
        -> SortDirection
        -> (Result -> m ())
        -> DBTransaction m ()

    , insertPolicies
        :: Set DB.Policy
        -> DBTransaction m ()

    , insertCheckpoints
        :: [Point]
        -> DBTransaction m ()

    , listCheckpointsDesc
        :: DBTransaction m [Point]

    , listAncestorsDesc
        :: SlotNo
        -> Int64 -- Number of ancestors to retrieve
        -> DBTransaction m [Point]

    , insertPatterns
        :: [Pattern]
        -> DBTransaction m ()

    , deletePattern
        :: Pattern
        -> DBTransaction m Int

    , listPatterns
        :: DBTransaction m [Pattern]

    , insertBinaryData
        :: [DB.BinaryData]
        -> DBTransaction m ()

    , getBinaryData
        :: DatumHash
        -> DBTransaction m (Maybe BinaryData)

    , pruneBinaryData
        :: DBTransaction m Int

    , insertScripts
        :: [DB.ScriptReference]
        -> DBTransaction m ()

    , getScript
        :: ScriptHash
        -> DBTransaction m (Maybe Script)

    , rollbackTo
        :: SlotNo
        -> DBTransaction m (Maybe SlotNo)

    , runTransaction
        :: forall a. ()
        => DBTransaction m a
        -> m a

    , longestRollback
        :: LongestRollback

    , close
        :: m ()
    }

type family DBTransaction (m :: Type -> Type) :: (Type -> Type) where
    DBTransaction IO = ReaderT Connection IO

data ConnectionType = ReadOnly | ReadWrite
    deriving (Generic, Eq, Show)

instance ToJSON ConnectionType where
    toEncoding = defaultGenericToEncoding

data DatabaseFile = OnDisk !FilePath | InMemory !(Maybe FilePath)
    deriving (Generic, Eq, Show)

-- | Construct a connection string for the SQLite database. This utilizes (and assumes) the URI
-- recognition from SQLite to choose between read-only or read-write database. By default also, when
-- no filepath is provided, the database is created in-memory with a shared cache.
--
-- For testing purpose however, it is also possible to create a in-memory database in isolation by
-- simply passing `:memory:` as a filepath.
mkConnectionString
    :: DatabaseFile
    -> ConnectionType
    -> String
mkConnectionString filePath mode =
    case (filePath, mode) of
        (OnDisk fp, ReadOnly)  ->
           "file:" <> fp <> "?mode=ro"
        (OnDisk fp, ReadWrite) ->
           "file:" <> fp <> "?mode=rwc"
        (InMemory Nothing, _ ) ->
           "file::kupo:?mode=memory&cache=shared"
        (InMemory (Just fp), _) ->
            fp

-- | A short-lived connection meant to be used in a resource-pool. These connections can be opened
-- either as read-only connection or read-write; depending on the client needs. Read-only connections
-- are non-blocking and can access data even when the database is being written concurrently.
createShortLivedConnection
    :: Tracer IO TraceDatabase
    -> ConnectionType
    -> DBLock IO
    -> LongestRollback
    -> DatabaseFile
    -> IO (Database IO)
createShortLivedConnection tr mode (DBLock shortLived longLived) k file = do
    traceWith tr $ DatabaseConnection ConnectionCreateShortLived{mode}
    conn <- Sqlite.open $ mkConnectionString file mode
    execute_ conn "PRAGMA page_size = 16184"
    execute_ conn "PRAGMA cache_size = -50000"
    when (mode == ReadOnly) $ execute_ conn "PRAGMA read_uncommitted = 1"
    return $ mkDatabase (contramap DatabaseConnection tr) mode k (bracketConnection conn)
  where
    bracketConnection :: Connection -> (forall a. ((Connection -> IO a) -> IO a))
    bracketConnection conn between =
        case mode of
            ReadOnly ->
                between conn
            ReadWrite ->
                bracket_
                    -- read-write connections only run when the longLived isn't busy working. Multiple
                    -- short-lived read-write connections may still conflict with one another, but
                    -- since they mostly are one-off requests, we simply retry them when busy/locked.
                    (atomically $ do
                        readTVar longLived >>= check . not
                        modifyTVar' shortLived next
                    )
                    (atomically (modifyTVar' shortLived prev))
                    (between conn)

-- | A resource acquisition bracket for a single long-lived connection. The system is assumed to use
-- with only once, at the application start-up and provide this connection to a privileged one which
-- takes priority over any other connections.
--
-- It is therefore also the connection from which we check for and run database migrations when
-- needed. Note that this bracket will also create the database if it doesn't exist.
withLongLivedConnection
    :: Tracer IO TraceDatabase
    -> DBLock IO
    -> LongestRollback
    -> DatabaseFile
    -> DeferIndexesInstallation
    -> (Database IO -> IO a)
    -> IO a
withLongLivedConnection tr (DBLock shortLived longLived) k file deferIndexes action = do
    withConnection (mkConnectionString file ReadWrite) $ \conn -> do
        databaseVersion conn >>= runMigrations tr conn
        installIndexes tr conn deferIndexes
        execute_ conn "PRAGMA synchronous = NORMAL"
        execute_ conn "PRAGMA journal_mode = WAL"
        execute_ conn "PRAGMA page_size = 16184"
        execute_ conn "PRAGMA foreign_keys = ON"
        action (mkDatabase (contramap DatabaseConnection tr) ReadWrite k (bracketConnection conn))
  where
    bracketConnection :: Connection -> (forall a. ((Connection -> IO a) -> IO a))
    bracketConnection conn between =
        bracket_
            (do
                atomically (writeTVar longLived True) -- acquire
                atomically (readTVar shortLived >>= check . (== 0)) -- wait for read-write short-lived
            )
            (atomically $ writeTVar longLived False)
            (between conn)

-- ** Lock

data DBLock (m :: Type -> Type) = DBLock !(TVar m Word) !(TVar m Bool)

newLock :: MonadSTM m => m (DBLock m)
newLock = DBLock <$> newTVarIO 0 <*> newTVarIO True

--
-- IO
--

mkDatabase
    :: Tracer IO TraceConnection
    -> ConnectionType
    -> LongestRollback
    -> (forall a. (Connection -> IO a) -> IO a)
    -> Database IO
mkDatabase tr mode longestRollback bracketConnection = Database
    { longestRollback

    , close = do
        traceWith tr ConnectionDestroyShortLived{mode}
        bracketConnection Sqlite.close

    , insertInputs = \inputs -> ReaderT $ \conn -> do
        mapM_
            (\DB.Input{..} -> do
                insertRow @"inputs" conn
                    [ SQLBlob extendedOutputReference
                    , SQLText address
                    , SQLBlob value
                    , maybe SQLNull SQLBlob datumHash
                    , maybe SQLNull SQLBlob refScriptHash
                    , SQLInteger (fromIntegral createdAtSlotNo)
                    , maybe SQLNull (SQLInteger . fromIntegral) spentAtSlotNo
                    ]
                case datum of
                    Nothing ->
                        pure ()
                    Just DB.BinaryData{..} ->
                        insertRow @"binary_data" conn
                            [ SQLBlob binaryDataHash
                            , SQLBlob binaryData
                            ]
                case refScript of
                    Nothing ->
                        pure ()
                    Just DB.ScriptReference{..} ->
                        insertRow @"scripts" conn
                            [ SQLBlob scriptHash
                            , SQLBlob script
                            ]
            )
            inputs

    , deleteInputs = \(toList -> refs) -> ReaderT $ \conn -> do
        fmap sum $ forM refs $ \ref -> do
            execute_ conn (deleteInputsQry ref)
            changes conn

    , markInputs = \(fromIntegral . unSlotNo -> slotNo) (toList -> refs) -> ReaderT $ \conn -> do
        fmap sum $ forM refs $ \ref -> do
            execute conn (markInputsQry ref)
                [ SQLInteger slotNo
                ]
            changes conn

    , pruneInputs = ReaderT $ \conn -> do
        traceWith tr (ConnectionBeginQuery "pruneInputs")
        withTemporaryIndex tr conn "inputsBySpentAt" "inputs(spent_at)" $ do
            execute conn pruneInputsQry [ SQLInteger (fromIntegral longestRollback) ]
        traceWith tr (ConnectionExitQuery "pruneInputs")
        changes conn

    , foldInputs = \pattern_ statusFlag sortDirection yield -> ReaderT $ \conn -> do
        traceWith tr (ConnectionBeginQuery "foldInputs")
        -- TODO: Allow resolving datums / scripts on demand through LEFT JOIN
        --
        -- See [#21](https://github.com/CardanoSolutions/kupo/issues/21)
        let (datum, refScript) = (Nothing, Nothing)
        Sqlite.fold_ conn (foldInputsQry pattern_ statusFlag sortDirection) () $ \() -> \case
            [  SQLBlob extendedOutputReference
             , SQLText address
             , SQLBlob value
             , matchMaybeBytes -> datumHash
             , matchMaybeBytes -> refScriptHash
             , SQLInteger (fromIntegral -> createdAtSlotNo)
             , SQLBlob createdAtHeaderHash
             , matchMaybeWord64 -> spentAtSlotNo
             , matchMaybeBytes -> spentAtHeaderHash
             ] ->
                yield (DB.resultFromRow DB.Input{..})
            (xs :: [SQLData]) ->
                throwIO (UnexpectedRow (patternToText pattern_) [xs])
        traceWith tr (ConnectionExitQuery "foldInputs")

    , insertPolicies = \policies -> ReaderT $ \conn ->
        mapM_
            (\DB.Policy{..} -> do
                insertRow @"policies" conn
                    [ SQLBlob outputReference
                    , SQLBlob policyId
                    ]
            )
            policies

    , insertCheckpoints = \cps -> ReaderT $ \conn -> do
        mapM_
            (\(DB.pointToRow -> DB.Checkpoint{..}) ->
                insertRow @"checkpoints" conn
                    [ SQLBlob checkpointHeaderHash
                    , SQLInteger (fromIntegral checkpointSlotNo)
                    ]
            )
            cps

    , listCheckpointsDesc = ReaderT $ \conn -> do
        let k = fromIntegral longestRollback
        let points =
                [ 0, 10 .. k `div` 2 ^ n ]
                ++
                [ k `div` (2 ^ e) | (e :: Integer) <- [ n-1, n-2 .. 0 ] ]
              where
                n = ceiling (log (fromIntegral @_ @Double k))
        fmap (fmap DB.pointFromRow . nubOn DB.checkpointSlotNo . mconcat) $ forM points $ \pt ->
            Sqlite.fold conn listCheckpointsQry [SQLInteger pt] [] $
                \xs (checkpointHeaderHash, checkpointSlotNo) ->
                    pure (DB.Checkpoint{..} : xs)

    , listAncestorsDesc = \(SlotNo slotNo) n -> ReaderT $ \conn -> do
        fmap reverse $
            Sqlite.fold conn listAncestorQry (SQLInteger <$> [fromIntegral slotNo, n]) [] $
                \xs (checkpointHeaderHash, checkpointSlotNo) ->
                    pure ((DB.pointFromRow DB.Checkpoint{..}) : xs)

    , insertPatterns = \patterns -> ReaderT $ \conn -> do
        mapM_
            (\pattern_ ->
                insertRow @"patterns" conn
                    [ SQLText (patternToText pattern_)
                    ]
            )
            patterns

    , insertBinaryData = \bin -> ReaderT $ \conn -> do
        mapM_
            (\DB.BinaryData{..} ->
                insertRow @"binary_data" conn
                    [ SQLBlob binaryDataHash
                    , SQLBlob binaryData
                    ]
            )
            bin

    , getBinaryData = \(DB.datumHashToRow -> binaryDataHash) -> ReaderT $ \conn -> do
        Sqlite.query conn getBinaryDataQry (Only (SQLBlob binaryDataHash)) <&> \case
            [[SQLBlob binaryData]] ->
                Just (DB.binaryDataFromRow DB.BinaryData{..})
            _notSQLBlob ->
                Nothing

    , pruneBinaryData = ReaderT $ \conn -> do
        traceWith tr (ConnectionBeginQuery "pruneBinaryData")
        execute_ conn pruneBinaryDataQry
        traceWith tr (ConnectionExitQuery "pruneBinaryData")
        changes conn

    , insertScripts = \scripts -> ReaderT $ \conn -> do
        mapM_
            (\DB.ScriptReference{..} ->
                insertRow @"scripts" conn
                    [ SQLBlob scriptHash
                    , SQLBlob script
                    ]
            )
            scripts

    , getScript = \(DB.scriptHashToRow -> scriptHash)-> ReaderT $ \conn -> do
        Sqlite.query conn getScriptQry (Only (SQLBlob scriptHash)) <&> \case
            [[SQLBlob script]] ->
                Just (DB.scriptFromRow DB.ScriptReference{..})
            _notSQLBlob ->
                Nothing

    , deletePattern = \pattern_-> ReaderT $ \conn -> do
        execute conn "DELETE FROM patterns WHERE pattern = ?"
            [ SQLText (DB.patternToRow pattern_)
            ]
        changes conn

    , listPatterns = ReaderT $ \conn -> do
        fold_ conn "SELECT * FROM patterns" []
            $ \xs (Only x) -> pure (DB.patternFromRow x:xs)

    , rollbackTo = \(SlotNo slotNo) -> ReaderT $ \conn -> do
        let slotNoVar = SQLInteger (fromIntegral slotNo)
        query_ conn selectMaxCheckpointQry >>= \case
            -- NOTE: Rolling back takes quite a bit of time and, when restarting
            -- the application, we'll always be asked to rollback to the
            -- _current tip_. In this case, there's nothing to delete or update,
            -- so we can safely skip it.
            [[SQLInteger slotNo']] | fromIntegral slotNo' == slotNo -> do
                pure ()
            _otherwise -> do
                traceWith tr $ ConnectionBeginQuery "rollbackTo"
                withTemporaryIndex tr conn "inputsBySpentAt" "inputs(spent_at)" $
                    withTemporaryIndex tr conn "inputsByCreatedAt" "inputs(created_at)" $ do
                        execute conn rollbackQry1 [ slotNoVar ]
                        execute conn rollbackQry2 [ slotNoVar ]
                        execute conn rollbackQry3 [ slotNoVar ]
                traceWith tr $ ConnectionExitQuery "rollbackTo"
        -- NOTE: It is good to run the 'PRAGMA optimize' every now-and-then. The
        -- SQLite's official documentation recommend to do so either upon
        -- closing every connection, or, every few hours. We do it after rolling
        -- back since this happens regularly but not too often, and, because
        -- after a rollback, a lot of things gets re-organized in the database
        -- so it's a good opportunity to tidy things up.
        execute_ conn "PRAGMA optimize"
        query_ conn selectMaxCheckpointQry >>= \case
            [[SQLInteger slotNo']] ->
                return $ Just (fromIntegral slotNo')
            [[SQLNull]] ->
                return Nothing
            xs ->
                throwIO $ UnexpectedRow ("MAX(" <> show slotNo <> ")") xs

    , runTransaction = \r -> bracketConnection $ \conn ->
        retryWhenBusy tr $ withTransaction conn mode (runReaderT r conn)
    }

insertRow
    :: forall tableName.
        ( KnownSymbol tableName
        )
    => Connection
    -> [SQLData]
    -> IO ()
insertRow conn r =
    let
        tableName = fromString (symbolVal (Proxy @tableName))
        values = mkPreparedStatement (length (toRow r))
        qry = "INSERT OR IGNORE INTO " <> tableName <> " VALUES " <> values
     in
        execute conn qry r

deleteInputsQry :: Pattern -> Query
deleteInputsQry pattern_ =
    Query $ "DELETE FROM inputs " <> patternToSql pattern_

markInputsQry :: Pattern -> Query
markInputsQry pattern_ =
    Query $ "UPDATE inputs SET spent_at = ? " <> patternToSql pattern_

pruneInputsQry :: Query
pruneInputsQry =
    "DELETE FROM inputs \
    \WHERE spent_at < ( \
    \  (SELECT MAX(slot_no) FROM checkpoints) - ?\
    \)"

foldInputsQry :: Pattern -> StatusFlag -> SortDirection -> Query
foldInputsQry pattern_ statusFlag sortDirection = Query $
    "SELECT \
      \ext_output_reference, address, value, datum_hash, script_hash ,\
      \created_at, createdAt.header_hash, \
      \spent_at, spentAt.header_hash \
    \FROM inputs \
    \JOIN \
      \checkpoints AS createdAt ON createdAt.slot_no = created_at \
    \LEFT OUTER JOIN \
      \checkpoints AS spentAt ON spentAt.slot_no = spent_at "
    <> patternToSql pattern_ <> " " <> statusFlagToSql statusFlag <> " \
    \ORDER BY \
      \created_at " <> ordering <> ", \
      \transaction_index " <> ordering <> ", \
      \output_index " <> ordering
  where
    ordering = case sortDirection of
        Asc -> "ASC"
        Desc -> "DESC"

listCheckpointsQry :: Query
listCheckpointsQry =
    "SELECT * FROM checkpoints \
    \WHERE slot_no >= ((SELECT MAX(slot_no) FROM checkpoints) - ?) \
    \ORDER BY slot_no ASC \
    \LIMIT 1"

listAncestorQry :: Query
listAncestorQry =
    "SELECT * FROM checkpoints \
    \WHERE slot_no < ? \
    \ORDER BY slot_no DESC \
    \LIMIT ?"

getBinaryDataQry :: Query
getBinaryDataQry =
    "SELECT binary_data FROM binary_data \
    \WHERE binary_data_hash = ? \
    \LIMIT 1"

-- NOTE: This removes all binary_data that aren't associted with any
-- known input. The 'ORDER BY' at the end may seem pointless but is
-- actually CRUCIAL for the query performance as it forces SQLite to use
-- the availables indexes of both tables on 'data_hash' and
-- 'binary_data_hash'. Without that, this query may take 1h+ on a large
-- database (e.g. mainnet matching '*').
pruneBinaryDataQry :: Query
pruneBinaryDataQry =
    " DELETE FROM binary_data \
    \ WHERE binary_data_hash IN ( \
    \   SELECT binary_data_hash FROM binary_data \
    \   LEFT JOIN inputs \
    \   ON binary_data_hash = inputs.datum_hash \
    \   WHERE inputs.ext_output_reference IS NULL \
    \   ORDER BY inputs.datum_hash \
    \ )"

getScriptQry :: Query
getScriptQry =
    "SELECT script FROM scripts \
    \WHERE script_hash = ? \
    \LIMIT 1"

selectMaxCheckpointQry :: Query
selectMaxCheckpointQry =
    "SELECT MAX(slot_no) FROM checkpoints"

rollbackQry1 :: Query
rollbackQry1 =
    "DELETE FROM inputs WHERE created_at > ?"

rollbackQry2 :: Query
rollbackQry2 =
    "UPDATE inputs SET spent_at = NULL WHERE spent_at > ?"

rollbackQry3 :: Query
rollbackQry3 =
    "DELETE FROM checkpoints WHERE slot_no > ?"

--
-- Helpers
--

mkPreparedStatement :: Int -> Query
mkPreparedStatement n =
    Query ("(" <> T.intercalate "," (replicate n "?") <> ")")
{-# INLINABLE mkPreparedStatement #-}

retryWhenBusy :: Tracer IO TraceConnection -> IO a -> IO a
retryWhenBusy tr action =
    action `catch` (\e@SQLError{sqlError} -> case sqlError of
        ErrorLocked -> do
            traceWith tr $ ConnectionLocked { retryingIn }
            threadDelay retryingIn
            retryWhenBusy tr action
        ErrorBusy -> do
            traceWith tr $ ConnectionBusy { retryingIn }
            threadDelay retryingIn
            retryWhenBusy tr action
        _otherError ->
            throwIO e
    )
  where
    retryingIn = 0.1

-- NOTE: Not using sqlite-simple's version because it lacks the crucial
-- 'onException' on commits; The commit operation may throw an 'SQLiteBusy'
-- exception when concurrent transactions are begin executed.
-- Yet, because it doesn't rollback in this case, it leaves the transaction in
-- an odd shrodinger state and makes it hard for the caller to properly handle
-- the exception (was the transaction rolled back or not? Is it safe to retry
-- it?). So, this slightly modified version makes sure to also rollback on a
-- failed commit; allowing caller to simply retry the whole transaction on
-- failure.
withTransaction :: Connection -> ConnectionType -> IO a -> IO a
withTransaction conn mode action =
  mask $ \restore -> do
    begin mode
    r <- restore action `onException` rollback
    commit `onException` rollback
    return r
  where
    begin = \case
        ReadOnly ->
            execute_ conn "BEGIN DEFERRED TRANSACTION"
        ReadWrite ->
            execute_ conn "BEGIN IMMEDIATE TRANSACTION"
    commit   = execute_ conn "COMMIT TRANSACTION"
    rollback = execute_ conn "ROLLBACK TRANSACTION"

matchMaybeBytes :: SQLData -> Maybe ByteString
matchMaybeBytes = \case
    SQLBlob bytes -> Just bytes
    _notSQLBlob -> Nothing
{-# INLINABLE matchMaybeBytes #-}

matchMaybeWord64 :: SQLData -> Maybe Word64
matchMaybeWord64 = \case
    SQLInteger (fromIntegral -> wrd) -> Just wrd
    _notSQLInteger -> Nothing
{-# INLINABLE matchMaybeWord64 #-}

--
-- Indexes
--

-- | Install database indexes if they do not already exists. Database indexes
-- make queries faster but they tend to make overall synchronization faster. Thus, when synchronizing
-- from scratch or over a long window it may be good idea to defer installation of some non-essential
-- database indexes.
installIndexes
    :: Tracer IO TraceDatabase
    -> Connection
    -> DeferIndexesInstallation
    -> IO ()
installIndexes tr conn = \case
    SkipNonEssentialIndexes -> do
        indexDoesExist conn "inputsByAddress" >>= \case
            True  -> do
                traceWith tr $ DatabaseDeferIndexes
                    "Asked to defer creation of database indexes but they already exist: did you \
                    \already start the indexer once and forgot to defer creation of indexes? \
                    \Consider creating the database anew and deferring indexes from the start if this \
                    \is indeed the intention."
            False -> do
                traceWith tr $ DatabaseDeferIndexes
                    "Creation of lookup indexes has been deferred: synchronization will be faster \
                    \but many queries will also be a lot longer. Consider installing indexes once \
                    \synchronization is done to speed up queries."
    InstallIndexesIfNotExist -> do
        installIndex tr conn
            "inputsByAddress"
            "inputs(address COLLATE NOCASE, spent_at)"
        installIndex tr conn
            "inputsByPaymentCredential"
            "inputs(payment_credential COLLATE NOCASE, spent_at)"
        installIndex tr conn
            "inputsByDatumHash"
            "inputs(datum_hash)"
        installIndex tr conn
            "inputsBySpentAt"
            "inputs(spent_at)"
        installIndex tr conn
            "inputsByCreatedAt"
            "inputs(created_at)"

-- Create the given index with some extra logging around it.
installIndex :: Tracer IO TraceDatabase -> Connection -> Text -> Text -> IO ()
installIndex tr conn name definition = do
    indexDoesExist conn name >>= \case
        False -> do
            traceWith tr (DatabaseCreateIndex name)
            execute_ conn $ Query $ unwords
                [ "CREATE INDEX IF NOT EXISTS"
                , name
                , "ON"
                , definition
                ]
        True ->
            traceWith tr (DatabaseIndexAlreadyExists name)

-- This creates an index on-the-fly if it is missing to make the subsequent queries fast-enough on
-- large databases. If the index was not there, it is removed afterwards. Otherwise, it is simply used
-- as such.
withTemporaryIndex :: Tracer IO TraceConnection -> Connection -> Text -> Text -> IO a -> IO a
withTemporaryIndex tr conn name definition action = do
    exists <- indexDoesExist conn "inputsByCreatedAt"
    unless exists $ traceWith tr (ConnectionCreateTemporaryIndex name)
    execute_ conn $ Query $ unwords
        [ "CREATE INDEX IF NOT EXISTS"
        , name
        , "ON"
        , definition
        ]
    a <- action
    unless exists $ do
        traceWith tr (ConnectionRemoveTemporaryIndex name)
        execute_ conn $ Query $ unwords
            [ "DROP INDEX"
            , name
            ]
    return a

-- | Check whether an index exists in the database. Handy to customize the behavior (e.g. logging)
-- depending on whether or not indexes are already there since 'CREATE INDEX IF NOT EXISTS' will not
-- tell whether or not it has indeed created something.
indexDoesExist :: Connection -> Text -> IO Bool
indexDoesExist conn name =
    query_ @[SQLData] conn (Query $ "PRAGMA index_info('" <> name <> "')") <&> \case
        [] -> False
        _doesExist -> True

--
-- Migrations
--

type MigrationRevision = Int

type Migration = [Query]

databaseVersion :: Connection -> IO MigrationRevision
databaseVersion conn =
    withStatement conn "PRAGMA user_version" $ \stmt -> do
        nextRow stmt >>= \case
            Just (Only version) ->
                pure version
            _unexpectedVersion ->
                throwIO UnexpectedUserVersion

runMigrations :: Tracer IO TraceDatabase -> Connection -> MigrationRevision -> IO ()
runMigrations tr conn currentVersion = do
    let missingMigrations = drop currentVersion migrations
    traceWith tr (DatabaseCurrentVersion currentVersion)
    if null missingMigrations then
        traceWith tr DatabaseNoMigrationNeeded
    else do
        let targetVersion = currentVersion + length missingMigrations
        traceWith tr $ DatabaseRunningMigration currentVersion targetVersion
        executeMigrations missingMigrations
  where
    executeMigrations = \case
        [] -> do
            pure ()
        (instructions):rest -> do
            void $ withTransaction conn ReadWrite $ traverse (execute_ conn) instructions
            executeMigrations rest

migrations :: [Migration]
migrations =
    [ mkMigration ix (decodeUtf8 migration)
    | (ix, migration) <- zip
        [1..]
        [ $(embedFile "db/v1.0.0-beta/001.sql")
        , $(embedFile "db/v1.0.0/001.sql")
        , $(embedFile "db/v1.0.0/002.sql")
        , $(embedFile "db/v1.0.1/001.sql")
        , $(embedFile "db/v2.0.0-beta/001.sql")
        , $(embedFile "db/v2.1.0/001.sql")
        , $(embedFile "db/v2.1.0/002.sql")
        , $(embedFile "db/v2.1.0/003.sql")
        ]
    ]
  where
    mkMigration :: Int -> Text -> Migration
    mkMigration i sql =
        ("PRAGMA user_version = " <> show i <> ";")
        : (fmap Query . filter (not . T.null . T.strip) . T.splitOn ";") sql

--
-- Exceptions
--

-- | Somehow, a 'PRAGMA user_version' didn't yield a number but, either nothing
-- or something else?
data UnexpectedUserVersionException
    = UnexpectedUserVersion
    deriving Show
instance Exception UnexpectedUserVersionException

-- | Something went wrong when unmarshalling data from the database.
data UnexpectedRowException
    = UnexpectedRow !Text ![[SQLData]]
    deriving Show
instance Exception UnexpectedRowException

--
-- Tracer
--

data TraceDatabase where
    DatabaseConnection
        :: { message :: TraceConnection }
        -> TraceDatabase
    DatabaseCurrentVersion
        :: { currentVersion :: Int }
        -> TraceDatabase
    DatabaseNoMigrationNeeded
        :: TraceDatabase
    DatabaseRunningMigration
        :: { from :: Int, to :: Int }
        -> TraceDatabase
    DatabaseCreateIndex
        :: { newIndex :: Text }
        -> TraceDatabase
    DatabaseIndexAlreadyExists
        :: { index :: Text }
        -> TraceDatabase
    DatabaseDeferIndexes
        :: { warning :: Text }
        -> TraceDatabase
    DatabaseRunningInMemory
        :: TraceDatabase
    deriving stock (Generic, Show)

instance ToJSON TraceDatabase where
    toEncoding =
        defaultGenericToEncoding

instance HasSeverityAnnotation TraceDatabase where
    getSeverityAnnotation = \case
        DatabaseConnection { message } -> getSeverityAnnotation message
        DatabaseCurrentVersion{}       -> Info
        DatabaseNoMigrationNeeded{}    -> Debug
        DatabaseRunningMigration{}     -> Notice
        DatabaseRunningInMemory{}      -> Warning
        DatabaseCreateIndex{}          -> Notice
        DatabaseIndexAlreadyExists{}   -> Debug
        DatabaseDeferIndexes{}         -> Warning

data TraceConnection where
    ConnectionCreateShortLived
        :: { mode :: ConnectionType }
        -> TraceConnection
    ConnectionDestroyShortLived
        :: { mode :: ConnectionType }
        -> TraceConnection
    ConnectionLocked
        :: { retryingIn :: DiffTime }
        -> TraceConnection
    ConnectionBusy
        :: { retryingIn :: DiffTime }
        -> TraceConnection
    ConnectionBeginQuery
        :: { beginQuery :: Text }
        -> TraceConnection
    ConnectionExitQuery
        :: { exitQuery :: Text }
        -> TraceConnection
    ConnectionCreateTemporaryIndex
        :: { newTemporaryIndex :: Text }
        -> TraceConnection
    ConnectionRemoveTemporaryIndex
        :: { dropTemporaryIndex :: Text }
        -> TraceConnection
    deriving stock (Generic, Show)

instance ToJSON TraceConnection where
    toEncoding =
        defaultGenericToEncoding

instance HasSeverityAnnotation TraceConnection where
    getSeverityAnnotation = \case
        ConnectionCreateShortLived{}     -> Debug
        ConnectionDestroyShortLived{}    -> Debug
        ConnectionLocked{}               -> Debug
        ConnectionBusy{}                 -> Debug
        ConnectionBeginQuery{}           -> Debug
        ConnectionExitQuery{}            -> Debug
        ConnectionCreateTemporaryIndex{} -> Notice
        ConnectionRemoveTemporaryIndex{} -> Debug
