module Contract.State
  ( defaultState
  , mkInitialState
  , handleQuery
  , handleAction
  ) where

import Prelude
import Contract.Types (Action(..), Query(..), Side(..), State, Tab(..), _confirmation, _contractId, _executionState, _side, _step, _tab)
import Control.Monad.Except (runExceptT)
import Control.Monad.Maybe.Trans (runMaybeT)
import Control.Monad.Reader (class MonadAsk)
import Control.Monad.Reader.Extra (mapEnvReaderT)
import Data.Foldable (for_)
import Data.Lens (assign, modifying, use)
import Data.Maybe (Maybe(..))
import Data.RawJson (RawJson(..))
import Data.Unfoldable as Unfoldable
import Effect.Aff.Class (class MonadAff)
import Env (Env)
import Foreign.Generic (encode)
import Foreign.JSON (unsafeStringify)
import Halogen (HalogenM)
import MainFrame.Types (ChildSlots, Msg)
import Marlowe.Execution (NamedAction(..), _namedActions, _state, initExecution, merge, mkTx, nextState)
import Marlowe.Semantics (Contract(..), Slot, _minSlot)
import Plutus.PAB.Webserver (postApiContractByContractinstanceidEndpointByEndpointname)

defaultState :: State
defaultState = mkInitialState zero Close

mkInitialState :: Slot -> Contract -> State
mkInitialState slot contract =
  { tab: Tasks
  , executionState: initExecution slot contract
  , side: Overview
  , confirmation: Nothing
  , contractId: Nothing
  , step: 0
  }

handleQuery :: forall a m. Query a -> HalogenM State Action ChildSlots Msg m (Maybe a)
handleQuery (ChangeSlot slot next) = do
  assign (_executionState <<< _state <<< _minSlot) slot
  pure $ Just next

handleQuery (ApplyTx tx next) = do
  modifying _executionState \currentExeState -> merge (nextState currentExeState tx) currentExeState
  pure $ Just next

handleAction ::
  forall m.
  MonadAff m =>
  MonadAsk Env m =>
  Action -> HalogenM State Action ChildSlots Msg m Unit
handleAction (ConfirmInput input) = do
  currentExeState <- use _executionState
  mContractId <- use _contractId
  for_ mContractId \contractId -> do
    let
      txInput = mkTx currentExeState (Unfoldable.fromMaybe input)

      json = RawJson <<< unsafeStringify <<< encode $ input
    -- TODO: currently we just ignore errors but we probably want to do something better in the future
    runMaybeT do
      void $ mapEnvReaderT _.ajaxSettings $ runExceptT $ postApiContractByContractinstanceidEndpointByEndpointname json contractId "apply-inputs"
      let
        executionState = nextState currentExeState txInput
      assign _executionState executionState

-- raise (SendWebSocketMessage (ServerMsg true)) -- FIXME: send txInput to the server to apply to the on-chain contract
handleAction (ChooseInput input) = assign _confirmation input

handleAction (ChangeChoice choiceId chosenNum) = modifying (_executionState <<< _namedActions) (map changeChoice)
  where
  changeChoice (MakeChoice choiceId' bounds _)
    | choiceId == choiceId' = MakeChoice choiceId bounds chosenNum

  changeChoice namedAction = namedAction

handleAction (SelectTab tab) = assign _tab tab

handleAction (FlipCard side) = assign _side side

-- Handled in MainFrame
handleAction ClosePanel = pure unit

handleAction (ChangeStep step) = assign _step step
