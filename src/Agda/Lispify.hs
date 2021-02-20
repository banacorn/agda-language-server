{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Agda.Lispify where

import Agda.Interaction.Base
import Agda.Interaction.BasicOps as B
import Agda.Interaction.EmacsCommand hiding (putResponse)
import Agda.Interaction.Highlighting.Emacs
import Agda.Interaction.Highlighting.Precise (TokenBased (..))
import Agda.Interaction.Imports (getAllWarningsOfTCErr)
import Agda.Interaction.InteractionTop (localStateCommandM)
import Agda.Interaction.Response as R
import Agda.Syntax.Abstract as A
import Agda.Syntax.Abstract.Pretty (prettyATop)
import Agda.Syntax.Common
import Agda.Syntax.Concrete as C
import Agda.Syntax.Position
import Agda.Syntax.Scope.Base
import Agda.TypeChecking.Errors (prettyError)
import Agda.TypeChecking.Monad hiding (Function)
import Agda.TypeChecking.Pretty (prettyTCM)
import qualified Agda.TypeChecking.Pretty as TCP
import Agda.TypeChecking.Pretty.Warning (prettyTCWarnings, prettyTCWarnings')
import Agda.TypeChecking.Warnings (WarningsAndNonFatalErrors (..))
import Agda.Utils.Function (applyWhen)
import Agda.Utils.Maybe
import Agda.Utils.Null (empty)
import Agda.Utils.Pretty
import Agda.Utils.String
import Agda.Utils.Time (CPUTime)
import Agda.VersionCommit
import Common (Reaction (..), FromAgda(..))
import Control.Monad.State hiding (state)
import qualified Data.List as List
import Data.String (IsString)

responseAbbr :: IsString a => Response -> a
responseAbbr res = case res of
  Resp_HighlightingInfo {} -> "Resp_HighlightingInfo"
  Resp_Status {} -> "Resp_Status"
  Resp_JumpToError {} -> "Resp_JumpToError"
  Resp_InteractionPoints {} -> "Resp_InteractionPoints"
  Resp_GiveAction {} -> "Resp_GiveAction"
  Resp_MakeCase {} -> "Resp_MakeCase"
  Resp_SolveAll {} -> "Resp_SolveAll"
  Resp_DisplayInfo {} -> "Resp_DisplayInfo"
  Resp_RunningInfo {} -> "Resp_RunningInfo"
  Resp_ClearRunningInfo {} -> "Resp_ClearRunningInfo"
  Resp_ClearHighlighting {} -> "Resp_ClearHighlighting"
  Resp_DoneAborting {} -> "Resp_DoneAborting"
  Resp_DoneExiting {} -> "Resp_DoneExiting"

----------------------------------

serialize :: Lisp String -> String
serialize = show . pretty

-- | Convert Response to an Reaction for the LSP client
responseToReaction :: Response -> TCM Reaction
responseToReaction (Resp_HighlightingInfo info remove method modFile) =
  ReactionNonLast . serialize <$> liftIO (lispifyHighlightingInfo info remove method modFile)
responseToReaction (Resp_DisplayInfo info) = ReactionNonLast . serialize <$> lispifyDisplayInfo info
responseToReaction (Resp_ClearHighlighting TokenBased) = return ReactionClearHighlightingTokenBased 
responseToReaction (Resp_ClearHighlighting NotOnlyTokenBased) = return ReactionClearHighlightingNotOnlyTokenBased 
responseToReaction Resp_DoneAborting = return ReactionDoneAborting 
responseToReaction Resp_DoneExiting = return ReactionDoneExiting
responseToReaction Resp_ClearRunningInfo = return ReactionClearRunningInfo
responseToReaction (Resp_RunningInfo n s) = return $ ReactionRunningInfo n s
responseToReaction (Resp_Status s) = return $ ReactionStatus (sChecked s) (sShowImplicitArguments s)
responseToReaction (Resp_JumpToError f p) = return $ ReactionJumpToError f (fromIntegral p)
responseToReaction (Resp_InteractionPoints is) =
  return $ ReactionInteractionPoints (map interactionId is)
responseToReaction (Resp_GiveAction i giveAction) =
  return $ ReactionGiveAction (fromAgda i) (fromAgda giveAction)
responseToReaction (Resp_MakeCase _ Function pcs) = return $ ReactionMakeCaseFunction pcs
responseToReaction (Resp_MakeCase _ ExtendedLambda pcs) = return $ ReactionMakeCaseExtendedLambda pcs
responseToReaction (Resp_SolveAll ps) = return $ ReactionSolveAll (map prn ps)
  where
    prn (i, e) = (fromAgda i, prettyShow e)

lispifyDisplayInfo :: DisplayInfo -> TCM (Lisp String)
lispifyDisplayInfo info = case info of
  Info_CompilationOk ws -> do
    warnings <- prettyTCWarnings (tcWarnings ws)
    errors <- prettyTCWarnings (nonFatalErrors ws)
    -- abusing the goals field since we ignore the title
    let (body, _) =
          formatWarningsAndErrors
            "The module was successfully compiled.\n"
            warnings
            errors
    format body "*Compilation result*"
  Info_Constraints s -> format (show $ vcat $ map pretty s) "*Constraints*"
  Info_AllGoalsWarnings ms ws -> do
    goals <- showGoals ms
    warnings <- prettyTCWarnings (tcWarnings ws)
    errors <- prettyTCWarnings (nonFatalErrors ws)
    let (body, title) = formatWarningsAndErrors goals warnings errors
    format body ("*All" ++ title ++ "*")
  Info_Auto s -> format s "*Auto*"
  Info_Error err -> do
    s <- showInfoError err
    format s "*Error*"
  Info_Time s -> format (render $ prettyTimed s) "*Time*"
  Info_NormalForm state cmode time expr -> do
    exprDoc <- evalStateT prettyExpr state
    let doc = maybe empty prettyTimed time $$ exprDoc
    format (render doc) "*Normal Form*"
    where
      prettyExpr =
        localStateCommandM $
          lift $
            B.atTopLevel $
              allowNonTerminatingReductions $
                (if computeIgnoreAbstract cmode then ignoreAbstractMode else inConcreteMode) $
                  B.showComputed cmode expr
  Info_InferredType state time expr -> do
    exprDoc <- evalStateT prettyExpr state
    let doc = maybe empty prettyTimed time $$ exprDoc
    format (render doc) "*Inferred Type*"
    where
      prettyExpr =
        localStateCommandM $
          lift $
            B.atTopLevel $
              TCP.prettyA expr
  Info_ModuleContents modules tel types -> do
    doc <- localTCState $ do
      typeDocs <- addContext tel $
        forM types $ \(x, t) -> do
          doc <- prettyTCM t
          return (prettyShow x, ":" <+> doc)
      return $
        vcat
          [ "Modules",
            nest 2 $ vcat $ map pretty modules,
            "Names",
            nest 2 $ align 10 typeDocs
          ]
    format (render doc) "*Module contents*"
  Info_SearchAbout hits names -> do
    hitDocs <- forM hits $ \(x, t) -> do
      doc <- prettyTCM t
      return (prettyShow x, ":" <+> doc)
    let doc =
          "Definitions about"
            <+> text (List.intercalate ", " $ words names) $$ nest 2 (align 10 hitDocs)
    format (render doc) "*Search About*"
  Info_WhyInScope s cwd v xs ms -> do
    doc <- explainWhyInScope s cwd v xs ms
    format (render doc) "*Scope Info*"
  Info_Context ii ctx -> do
    doc <- localTCState (prettyResponseContext ii False ctx)
    format (render doc) "*Context*"
  Info_Intro_NotFound -> format "No introduction forms found." "*Intro*"
  Info_Intro_ConstructorUnknown ss -> do
    let doc =
          sep
            [ "Don't know which constructor to introduce of",
              let mkOr [] = []
                  mkOr [x, y] = [text x <+> "or" <+> text y]
                  mkOr (x : xs) = text x : mkOr xs
               in nest 2 $ fsep $ punctuate comma (mkOr ss)
            ]
    format (render doc) "*Intro*"
  Info_Version -> format ("Agda version " ++ versionWithCommitInfo) "*Agda Version*"
  Info_GoalSpecific ii kind -> lispifyGoalSpecificDisplayInfo ii kind

lispifyGoalSpecificDisplayInfo :: InteractionId -> GoalDisplayInfo -> TCM (Lisp String)
lispifyGoalSpecificDisplayInfo ii kind = localTCState $
  B.withInteractionId ii $
    case kind of
      Goal_HelperFunction helperType -> do
        doc <- inTopContext $ prettyATop helperType
        return $
          L
            [ A "agda2-info-action-and-copy",
              A $ quote "*Helper function*",
              A $ quote (render doc ++ "\n"),
              A "nil"
            ]
      Goal_NormalForm cmode expr -> do
        doc <- showComputed cmode expr
        format (render doc) "*Normal Form*" -- show?
      Goal_GoalType norm aux ctx bndry constraints -> do
        ctxDoc <- prettyResponseContext ii True ctx
        goalDoc <- prettyTypeOfMeta norm ii
        auxDoc <- case aux of
          GoalOnly -> return empty
          GoalAndHave expr -> do
            doc <- prettyATop expr
            return $ "Have:" <+> doc
          GoalAndElaboration term -> do
            doc <- TCP.prettyTCM term
            return $ "Elaborates to:" <+> doc
        let boundaryDoc
              | null bndry = []
              | otherwise =
                [ text $ delimiter "Boundary",
                  vcat $ map pretty bndry
                ]
        let constraintsDoc =
              if null constraints
                then []
                else
                  [ text $ delimiter "Constraints",
                    vcat $ map pretty constraints
                  ]
        let doc =
              vcat $
                [ "Goal:" <+> goalDoc,
                  auxDoc,
                  vcat boundaryDoc,
                  text (replicate 60 '\x2014'),
                  ctxDoc
                ]
                  ++ constraintsDoc
        format (render doc) "*Goal type etc.*"
      Goal_CurrentGoal norm -> do
        doc <- prettyTypeOfMeta norm ii
        format (render doc) "*Current Goal*"
      Goal_InferredType expr -> do
        doc <- prettyATop expr
        format (render doc) "*Inferred Type*"

-- | Format responses of DisplayInfo
format :: String -> String -> TCM (Lisp String)
format content bufname = return (display_info' False bufname content)

--------------------------------------------------------------------------------

-- | Given strings of goals, warnings and errors, return a pair of the
--   body and the title for the info buffer
formatWarningsAndErrors :: String -> String -> String -> (String, String)
formatWarningsAndErrors g w e = (body, title)
  where
    isG = not $ null g
    isW = not $ null w
    isE = not $ null e
    title =
      List.intercalate "," $
        catMaybes
          [ " Goals" <$ guard isG,
            " Errors" <$ guard isE,
            " Warnings" <$ guard isW,
            " Done" <$ guard (not (isG || isW || isE))
          ]

    body =
      List.intercalate "\n" $
        catMaybes
          [ g <$ guard isG,
            delimiter "Errors" <$ guard (isE && (isG || isW)),
            e <$ guard isE,
            delimiter "Warnings" <$ guard (isW && (isG || isE)),
            w <$ guard isW
          ]

-- | Serializing Info_Error
showInfoError :: Info_Error -> TCM String
showInfoError (Info_GenericError err) = do
  e <- prettyError err
  w <- prettyTCWarnings' =<< getAllWarningsOfTCErr err

  let errorMsg =
        if null w
          then e
          else delimiter "Error" ++ "\n" ++ e
  let warningMsg =
        List.intercalate "\n" $
          delimiter "Warning(s)" :
          filter (not . null) w
  return $
    if null w
      then errorMsg
      else errorMsg ++ "\n\n" ++ warningMsg
showInfoError (Info_CompilationError warnings) = do
  s <- prettyTCWarnings warnings
  return $
    unlines
      [ "You need to fix the following errors before you can compile",
        "the module:",
        "",
        s
      ]
showInfoError (Info_HighlightingParseError ii) =
  return $ "Highlighting failed to parse expression in " ++ show ii
showInfoError (Info_HighlightingScopeCheckError ii) =
  return $ "Highlighting failed to scope check expression in " ++ show ii

explainWhyInScope ::
  FilePath ->
  String ->
  Maybe LocalVar ->
  [AbstractName] ->
  [AbstractModule] ->
  TCM Doc
explainWhyInScope s _ Nothing [] [] = TCP.text (s ++ " is not in scope.")
explainWhyInScope s _ v xs ms =
  TCP.vcat
    [ TCP.text (s ++ " is in scope as"),
      TCP.nest 2 $ TCP.vcat [variable v xs, modules ms]
    ]
  where
    -- variable :: Maybe _ -> [_] -> TCM Doc
    variable Nothing vs = names vs
    variable (Just x) vs
      | null vs = asVar
      | otherwise =
        TCP.vcat
          [ TCP.sep [asVar, TCP.nest 2 $ shadowing x],
            TCP.nest 2 $ names vs
          ]
      where
        asVar :: TCM Doc
        asVar =
          "* a variable bound at" TCP.<+> TCP.prettyTCM (nameBindingSite $ localVar x)
        shadowing :: LocalVar -> TCM Doc
        shadowing (LocalVar _ _ []) = "shadowing"
        shadowing _ = "in conflict with"
    names = TCP.vcat . map pName
    modules = TCP.vcat . map pMod

    pKind = \case
      ConName -> "constructor"
      FldName -> "record field"
      PatternSynName -> "pattern synonym"
      GeneralizeName -> "generalizable variable"
      DisallowedGeneralizeName -> "generalizable variable from let open"
      MacroName -> "macro name"
      QuotableName -> "quotable name"
      -- previously DefName:
      DataName -> "data type"
      RecName -> "record type"
      AxiomName -> "postulate"
      PrimName -> "primitive function"
      FunName -> "defined name"
      OtherDefName -> "defined name"

    pName :: AbstractName -> TCM Doc
    pName a =
      TCP.sep
        [ "* a"
            TCP.<+> pKind (anameKind a)
            TCP.<+> TCP.text (prettyShow $ anameName a),
          TCP.nest 2 "brought into scope by"
        ]
        TCP.$$ TCP.nest 2 (pWhy (nameBindingSite $ qnameName $ anameName a) (anameLineage a))
    pMod :: AbstractModule -> TCM Doc
    pMod a =
      TCP.sep
        [ "* a module" TCP.<+> TCP.text (prettyShow $ amodName a),
          TCP.nest 2 "brought into scope by"
        ]
        TCP.$$ TCP.nest 2 (pWhy (nameBindingSite $ qnameName $ mnameToQName $ amodName a) (amodLineage a))

    pWhy :: Range -> WhyInScope -> TCM Doc
    pWhy r Defined = "- its definition at" TCP.<+> TCP.prettyTCM r
    pWhy r (Opened (C.QName x) w) | isNoName x = pWhy r w
    pWhy r (Opened m w) =
      "- the opening of"
        TCP.<+> TCP.prettyTCM m
        TCP.<+> "at"
        TCP.<+> TCP.prettyTCM (getRange m)
        TCP.$$ pWhy r w
    pWhy r (Applied m w) =
      "- the application of"
        TCP.<+> TCP.prettyTCM m
        TCP.<+> "at"
        TCP.<+> TCP.prettyTCM (getRange m)
        TCP.$$ pWhy r w

-- | Pretty-prints the context of the given meta-variable.
prettyResponseContext ::
  -- | Context of this meta-variable.
  InteractionId ->
  -- | Print the elements in reverse order?
  Bool ->
  [ResponseContextEntry] ->
  TCM Doc
prettyResponseContext ii rev ctx = withInteractionId ii $ do
  modality <- asksTC getModality
  align 10 . concat . applyWhen rev reverse <$> do
    forM ctx $ \(ResponseContextEntry n x (Arg ai expr) letv nis) -> do
      let prettyCtxName :: String
          prettyCtxName
            | n == x = prettyShow x
            | isInScope n == InScope = prettyShow n ++ " = " ++ prettyShow x
            | otherwise = prettyShow x

          -- Some attributes are useful to report whenever they are not
          -- in the default state.
          attribute :: String
          attribute = c ++ if null c then "" else " "
            where
              c = prettyShow (getCohesion ai)

          extras :: [Doc]
          extras =
            concat
              [ ["not in scope" | isInScope nis == C.NotInScope],
                -- Print erased if hypothesis is erased by goal is non-erased.
                ["erased" | not $ getQuantity ai `moreQuantity` getQuantity modality],
                -- Print irrelevant if hypothesis is strictly less relevant than goal.
                ["irrelevant" | not $ getRelevance ai `moreRelevant` getRelevance modality],
                -- Print instance if variable is considered by instance search
                ["instance" | isInstance ai]
              ]
      ty <- prettyATop expr
      maybeVal <- traverse prettyATop letv

      return $
        (attribute ++ prettyCtxName, ":" <+> ty <+> parenSep extras) :
          [(prettyShow x, "=" <+> val) | val <- maybeToList maybeVal]
  where
    parenSep :: [Doc] -> Doc
    parenSep docs
      | null docs = empty
      | otherwise = (" " <+>) $ parens $ fsep $ punctuate comma docs

-- | Pretty-prints the type of the meta-variable.
prettyTypeOfMeta :: Rewrite -> InteractionId -> TCM Doc
prettyTypeOfMeta norm ii = do
  form <- B.typeOfMeta norm ii
  case form of
    OfType _ e -> prettyATop e
    _ -> prettyATop form

-- | Prefix prettified CPUTime with "Time:"
prettyTimed :: CPUTime -> Doc
prettyTimed time = "Time:" <+> pretty time