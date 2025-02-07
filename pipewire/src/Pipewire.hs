module Pipewire (
    -- * High level API
    PwInstance (..),
    RegistryEvent (..),
    withInstance,
    runInstance,
    quitInstance,
    CoreError (..),
    syncState,
    syncState_,
    readState,

    -- * Mid level bracket API
    withPipewire,
    withMainLoop,
    withContext,
    withCore,

    -- * Protocol
    module Pipewire.Protocol,
    module Pipewire.Enum,

    -- * Core API

    -- ** Initialization
    module Pipewire.CoreAPI.Initialization,

    -- ** Main Loop
    module Pipewire.CoreAPI.MainLoop,

    -- ** Context
    module Pipewire.CoreAPI.Context,

    -- ** Core
    module Pipewire.CoreAPI.Core,

    -- ** Link
    module Pipewire.CoreAPI.Link,
    waitForLink,

    -- ** Loop
    module Pipewire.CoreAPI.Loop,

    -- ** Proxy
    module Pipewire.CoreAPI.Proxy,

    -- ** Registry
    module Pipewire.CoreAPI.Registry,

    -- * Utilities

    -- ** Properties
    module Pipewire.Utilities.Properties,

    -- * SPA

    -- ** Utilities

    -- *** Dictionary
    module Pipewire.SPA.Utilities.Dictionary,

    -- *** Hooks
    module Pipewire.SPA.Utilities.Hooks,

    -- * SPA
    module Pipewire.Stream,

    -- * Helpers
    getHeadersVersion,
    getLibraryVersion,
    cfloatVector,
)
where

import Control.Exception (bracket, bracket_)
import Language.C.Inline qualified as C

import Control.Concurrent (MVar, modifyMVar_, newMVar, readMVar, withMVar)
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NE
import Pipewire.CoreAPI.Context (PwContext, pw_context_connect, pw_context_destroy, pw_context_new)
import Pipewire.CoreAPI.Core (DoneHandler, ErrorHandler, InfoHandler, PwCore, PwCoreEvents, PwCoreInfo, PwRegistry, pw_core_add_listener, pw_core_disconnect, pw_core_get_registry, pw_core_sync, pw_id_core, withCoreEvents)
import Pipewire.CoreAPI.Initialization (pw_deinit, pw_init)
import Pipewire.CoreAPI.Link (LinkProperties (..), LinkState, PwLink (..), newLinkProperties, pwLinkEventsFuncs, pw_link_create, withLink, withPwLinkEvents)
import Pipewire.CoreAPI.Loop (PwLoop)
import Pipewire.CoreAPI.MainLoop (PwMainLoop, pw_main_loop_destroy, pw_main_loop_get_loop, pw_main_loop_new, pw_main_loop_quit, pw_main_loop_run, withSignalsHandler)
import Pipewire.CoreAPI.Proxy (PwProxy, pw_proxy_add_object_listener, pw_proxy_destroy, withProxyEvents)
import Pipewire.CoreAPI.Registry (GlobalHandler, GlobalRemoveHandler, pw_registry_add_listener, pw_registry_destroy, withRegistryEvents)
import Pipewire.Enum
import Pipewire.Prelude
import Pipewire.Protocol (PwID (..), PwVersion (..), SeqID (..))
import Pipewire.SPA.Utilities.Dictionary (SpaDict, spaDictLookup, spaDictLookupInt, spaDictRead, withSpaDict)
import Pipewire.SPA.Utilities.Hooks (SpaHook, withSpaHook)
import Pipewire.Stream (pw_stream_get_node_id)
import Pipewire.Utilities.Properties (PwProperties, pw_properties_get, pw_properties_new, pw_properties_new_dict, pw_properties_set, pw_properties_set_id, pw_properties_set_linger)

C.include "<pipewire/pipewire.h>"

withPipewire :: IO a -> IO a
withPipewire = bracket_ pw_init pw_deinit

-- | Setup a main loop with signal handlers
withMainLoop :: (PwMainLoop -> IO a) -> IO a
withMainLoop cb = bracket pw_main_loop_new pw_main_loop_destroy withHandler
  where
    withHandler mainLoop = withSignalsHandler mainLoop (cb mainLoop)

withContext :: PwLoop -> (PwContext -> IO a) -> IO a
withContext loop = bracket (pw_context_new loop) pw_context_destroy

withCore :: PwContext -> (PwCore -> IO a) -> IO a
withCore context = bracket (pw_context_connect context) pw_core_disconnect

getHeadersVersion :: IO Text
getHeadersVersion = ([C.exp| const char*{pw_get_headers_version()} |] :: IO CString) >>= peekCString

getLibraryVersion :: IO Text
getLibraryVersion = ([C.exp| const char*{pw_get_library_version()} |] :: IO CString) >>= peekCString

-- | A pipewire client instance
data PwInstance state = PwInstance
    { stateVar :: MVar state
    , mainLoop :: PwMainLoop
    , core :: PwCore
    , registry :: PwRegistry
    , sync :: IORef SeqID
    , errorsVar :: MVar [CoreError]
    }

-- | A pipewire error
data CoreError = CoreError
    { pwid :: PwID
    , code :: Int
    , message :: Text
    }
    deriving (Show)

-- | A registry event
data RegistryEvent = Added PwID Text SpaDict | Removed PwID

-- TODO: handle pw_main_loop error

-- | Run the main loop
runInstance :: PwInstance state -> IO (Maybe (NonEmpty CoreError))
runInstance pwInstance = do
    void $ pw_main_loop_run pwInstance.mainLoop
    getErrors pwInstance

readState :: PwInstance state -> IO state
readState pwInstance = readMVar pwInstance.stateVar

-- | Terminate the main loop, to be called from handlers.
quitInstance :: PwInstance state -> IO ()
quitInstance pwInstance = void $ pw_main_loop_quit pwInstance.mainLoop

{- | Like 'syncState' but throwing an error if there was any pipewire error.
Do not call from a handler!
-}
syncState_ :: PwInstance state -> (state -> IO a) -> IO a
syncState_ pwInstance cb = syncState pwInstance \case
    Left errs -> mapM_ print errs >> error "pw core failed"
    Right state -> cb state

getErrors :: PwInstance state -> IO (Maybe (NonEmpty CoreError))
getErrors pwInstance = NE.nonEmpty <$> readMVar pwInstance.errorsVar

{- | Ensure all the events have been processed and access the state.
Do not call from a handler!
-}
syncState :: PwInstance state -> (Either (NonEmpty CoreError) state -> IO a) -> IO a
syncState pwInstance cb = do
    -- Write the expected SeqID so that the core handler stop the loop
    writeIORef pwInstance.sync =<< pw_core_sync pwInstance.core pw_id_core
    -- Start the loop
    pw_main_loop_run pwInstance.mainLoop
    -- Call back with the finalized state
    getErrors pwInstance >>= \case
        Just errs -> cb (Left errs)
        Nothing -> withMVar pwInstance.stateVar (cb . Right)

-- | Create a new 'PwInstance' by providing an initial state and a registry update handler.
withInstance :: state -> (PwInstance state -> RegistryEvent -> state -> IO state) -> (PwInstance state -> IO a) -> IO a
withInstance initialState updateState cb =
    withPipewire do
        withMainLoop $ \mainLoop -> do
            loop <- pw_main_loop_get_loop mainLoop
            withContext loop \context -> do
                withCore context \core -> do
                    sync <- newIORef (SeqID 0)
                    errorsVar <- newMVar []
                    withCoreEvents infoHandler (doneHandler mainLoop sync) (errorHandler errorsVar) \coreEvents -> do
                        withSpaHook \coreListener -> do
                            pw_core_add_listener core coreListener coreEvents
                            withSpaHook \registryListener -> do
                                stateVar <- newMVar initialState
                                registry <- pw_core_get_registry core
                                let pwInstance = PwInstance{stateVar, errorsVar, mainLoop, sync, core, registry}
                                withRegistryEvents (handler pwInstance stateVar) (removeHandler pwInstance stateVar) \registryEvent -> do
                                    pw_registry_add_listener registry registryListener registryEvent
                                    cb pwInstance
  where
    handler pwInstance stateVar pwid name _ props = modifyMVar_ stateVar (updateState pwInstance $ Added pwid name props)
    removeHandler pwInstance stateVar pwid = modifyMVar_ stateVar (updateState pwInstance $ Removed pwid)
    infoHandler _pwinfo = pure ()
    errorHandler errorVar pwid _seq' res msg = modifyMVar_ errorVar (\xs -> pure $ CoreError pwid res msg : xs)
    doneHandler mainLoop sync _pwid seqid = do
        pending <- readIORef sync
        when (pending == seqid) do
            void $ pw_main_loop_quit mainLoop

waitForLink :: PwLink -> PwInstance state -> IO (Maybe (NonEmpty CoreError))
waitForLink pwLink pwInstance = do
    let abort msg = putStrLn msg >> quitInstance pwInstance
        destroyHandler = abort "Destroyed!"
        removedHandler = abort "Proxy Removed!"
        errorHandler res err = abort $ "error: " <> show res <> " " <> show err
    withProxyEvents pwLink.getProxy destroyHandler removedHandler errorHandler do
        let infoHandler pwid state = case state of
                Left err -> abort $ "Link state failed: " <> show err
                Right PW_LINK_STATE_ACTIVE -> do
                    putStrLn "Link is active, quiting the loop!"
                    quitInstance pwInstance
                Right x -> do
                    putStrLn $ "Link state pwid " <> show pwid <> ": " <> show x
                    quitInstance pwInstance

        withSpaHook \spaHook ->
            withPwLinkEvents infoHandler \ple -> do
                pw_proxy_add_object_listener pwLink.getProxy spaHook (pwLinkEventsFuncs ple)
                putStrLn "Waiting for link..."
                runInstance pwInstance
