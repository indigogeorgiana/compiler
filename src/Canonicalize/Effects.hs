module Canonicalize.Effects (canonicalize, toValues, checkForeignType) where

import qualified Data.Foldable as F
import qualified Data.Traversable as T

import qualified AST.Effects as Effects
import qualified AST.Type as T
import qualified AST.Variable as Var
import qualified Reporting.Annotation as A
import qualified Reporting.Error.Canonicalize as Error
import qualified Reporting.Region as R
import qualified Reporting.Result as Result
import qualified Canonicalize.Environment as Env
import qualified Canonicalize.Type as Canonicalize
import Canonicalize.Variable (Result)



-- TO EXPORT VALUES


toValues :: Effects.Raw -> [Var.Value]
toValues effects =
  case effects of
    Effects.None ->
      []

    Effects.Manager _ ->
      []

    Effects.Foreign foreigns ->
      map (Var.Value . Effects._rawName . A.drop) foreigns



-- CANONICALIZE


canonicalize :: Env.Environment -> Effects.Raw -> Result Effects.Canonical
canonicalize env effects =
  case effects of
    Effects.None ->
      Result.ok Effects.None

    Effects.Manager info ->
      Result.ok (Effects.Manager info)

    Effects.Foreign rawForeigns ->
      Effects.Foreign <$> T.traverse (canonicalizeRawForeign env) rawForeigns


canonicalizeRawForeign
  :: Env.Environment
  -> A.Commented Effects.ForeignRaw
  -> Result (A.Commented Effects.ForeignCanonical)
canonicalizeRawForeign env (A.A ann (Effects.ForeignRaw name rawType)) =
  do  tipe <- Canonicalize.tipe env rawType
      kind <- figureOutKind (fst ann) name tipe
      Result.ok (A.A ann (Effects.ForeignCanonical name kind tipe))


figureOutKind :: R.Region -> String -> T.Canonical -> Result Effects.Kind
figureOutKind region name rootType =
  case T.deepDealias rootType of
    T.Lambda outgoingType (T.App (T.Type effect) [T.Var _])
      | effect == Var.cmd ->
          pure (Effects.Cmd outgoingType)
            <* checkForeignType (makeError region name "command") outgoingType

    T.Lambda (T.Lambda incomingType (T.Var msg1)) (T.App (T.Type effect) [T.Var msg2])
      | effect == Var.sub && msg1 == msg2 ->
          pure (Effects.Sub incomingType)
            <* checkForeignType (makeError region name "subscription") incomingType

    _ ->
      Result.throw region (error "TODO - bad overall type")


makeError :: R.Region -> String -> String -> T.Canonical -> Maybe String -> A.Located Error.Error
makeError region name kind tipe maybeMessage =
  A.A region (Error.foreign name kind tipe maybeMessage)



-- CHECK INCOMING AND OUTGOING TYPES


checkForeignType
  :: (Monoid i)
  => (T.Canonical -> Maybe String -> A.Located e)
  -> T.Canonical
  -> Result.Result i w e ()
checkForeignType makeError tipe =
  let
    check =
      checkForeignType makeError

    throw maybeMsg =
      Result.throwMany [makeError tipe maybeMsg]
  in
    case tipe of
      T.Aliased _ args aliasedType ->
        check (T.dealias args aliasedType)

      T.Type name ->
        if Var.isJson name || Var.isPrimitive name || Var.isTuple name then
          return ()

        else
          throw Nothing

      T.App name [] ->
          check name

      T.App (T.Type name) [arg]
          | Var.isMaybe name -> check arg
          | Var.isArray name -> check arg
          | Var.isList  name -> check arg

      T.App (T.Type name) args
          | Var.isTuple name ->
              F.traverse_ check args

      T.App _ _ ->
          throw Nothing

      T.Var _ ->
          throw (Just "free type variable")

      T.Lambda _ _ ->
          throw (Just "function")

      T.Record _ (Just _) ->
          throw (Just "extended record")

      T.Record fields Nothing ->
          F.traverse_ (\(k,v) -> (,) k <$> check v) fields
