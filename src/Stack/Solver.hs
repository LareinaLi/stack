{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE DataKinds             #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TypeFamilies          #-}
module Stack.Solver
    ( cabalPackagesCheck
    , findCabalFiles
    , getResolverConstraints
    , mergeConstraints
    , solveExtraDeps
    , solveResolverSpec
    -- * Internal - for tests
    , parseCabalOutputLine
    ) where

import           Prelude ()
import           Prelude.Compat

import           Control.Applicative
import           Control.Monad (when,void,join,liftM,unless,mapAndUnzipM, zipWithM_)
import           Control.Monad.IO.Unlift
import           Control.Monad.Logger
import           Data.Aeson.Extended         (object, (.=), toJSON)
import qualified Data.ByteString as S
import           Data.Char (isSpace)
import           Data.Either
import           Data.Foldable (forM_)
import           Data.Function (on)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import           Data.List                   ( (\\), isSuffixOf, intercalate
                                             , minimumBy, isPrefixOf)
import           Data.List.Extra (groupSortOn)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe (catMaybes, isNothing, mapMaybe)
import           Data.Monoid
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Text.Encoding (decodeUtf8, encodeUtf8)
import           Data.Text.Encoding.Error (lenientDecode)
import           Data.Text.Extra (stripCR)
import qualified Data.Text.Lazy as LT
import           Data.Text.Lazy.Encoding (decodeUtf8With)
import           Data.Tuple (swap)
import qualified Data.Yaml as Yaml
import qualified Distribution.Package as C
import qualified Distribution.PackageDescription as C
import qualified Distribution.Text as C
import           Path
import           Path.Find (findFiles)
import           Path.IO hiding (findExecutable, findFiles)
import           Stack.Build.Target (gpdVersion)
import           Stack.BuildPlan
import           Stack.Config (getLocalPackages, loadConfigYaml)
import           Stack.Constants (stackDotYaml, wiredInPackages)
import           Stack.Package               (printCabalFileWarning
                                             , hpack
                                             , readPackageUnresolved)
import           Stack.PrettyPrint
import           Stack.Setup
import           Stack.Setup.Installed
import           Stack.Snapshot (loadSnapshot)
import           Stack.Types.Build
import           Stack.Types.BuildPlan
import           Stack.Types.Compiler
import           Stack.Types.Config
import           Stack.Types.FlagName
import           Stack.Types.PackageIdentifier
import           Stack.Types.PackageName
import           Stack.Types.Resolver
import           Stack.Types.StackT (StackM)
import           Stack.Types.Version
import qualified System.Directory as D
import qualified System.FilePath as FP
import           System.Process.Read
import           Text.Regex.Applicative.Text (match, sym, psym, anySym, few)

import qualified Data.Text.Normalize as T ( normalize , NormalizationMode(NFC) )

data ConstraintType = Constraint | Preference deriving (Eq)
type ConstraintSpec = Map PackageName (Version, Map FlagName Bool)

cabalSolver :: (StackM env m, HasConfig env)
            => EnvOverride
            -> [Path Abs Dir] -- ^ cabal files
            -> ConstraintType
            -> ConstraintSpec -- ^ src constraints
            -> ConstraintSpec -- ^ dep constraints
            -> [String] -- ^ additional arguments
            -> m (Either [PackageName] ConstraintSpec)
cabalSolver menv cabalfps constraintType
            srcConstraints depConstraints cabalArgs =
  withRunIO $ \run -> withSystemTempDir "cabal-solver" $ \dir' -> run $ do

    let versionConstraints = fmap fst depConstraints
        dir = toFilePath dir'
    configLines <- getCabalConfig dir constraintType versionConstraints
    let configFile = dir FP.</> "cabal.config"
    liftIO $ S.writeFile configFile $ encodeUtf8 $ T.unlines configLines

    -- Run from a temporary directory to avoid cabal getting confused by any
    -- sandbox files, see:
    -- https://github.com/commercialhaskell/stack/issues/356
    --
    -- In theory we could use --ignore-sandbox, but not all versions of cabal
    -- support it.
    tmpdir <- getTempDir

    let args = ("--config-file=" ++ configFile)
             : "install"
             : "--enable-tests"
             : "--enable-benchmarks"
             : "--dry-run"
             : "--reorder-goals"
             : "--max-backjumps=-1"
             : "--package-db=clear"
             : "--package-db=global"
             : cabalArgs ++
               toConstraintArgs (flagConstraints constraintType) ++
               fmap toFilePath cabalfps

    catch (liftM Right (readProcessStdout (Just tmpdir) menv "cabal" args))
          (\ex -> case ex of
              ProcessFailed _ _ _ err -> return $ Left err
              _ -> throwM ex)
    >>= either parseCabalErrors parseCabalOutput

  where
    errCheck = T.isInfixOf "Could not resolve dependencies"
    linesNoCR = map stripCR . T.lines
    cabalBuildErrMsg e =
               ">>>> Cabal errors begin\n"
            <> e
            <> "<<<< Cabal errors end\n"

    parseCabalErrors err = do
        let errExit e = error $ "Could not parse cabal-install errors:\n\n"
                              ++ cabalBuildErrMsg (T.unpack e)
            msg = LT.toStrict $ decodeUtf8With lenientDecode err

        if errCheck msg then do
            $logInfo "Attempt failed.\n"
            $logInfo $ cabalBuildErrMsg msg
            let pkgs = parseConflictingPkgs msg
                mPkgNames = map (C.simpleParse . T.unpack) pkgs
                pkgNames  = map (fromCabalPackageName . C.pkgName)
                                (catMaybes mPkgNames)

            when (any isNothing mPkgNames) $ do
                  $logInfo $ "*** Only some package names could be parsed: " <>
                      T.pack (intercalate ", " (map show pkgNames))
                  error $ T.unpack $
                       "*** User packages involved in cabal failure: "
                       <> T.intercalate ", " (parseConflictingPkgs msg)

            if pkgNames /= [] then do
                  return $ Left pkgNames
            else errExit msg
        else errExit msg

    parseConflictingPkgs msg =
        let ls = dropWhile (not . errCheck) $ linesNoCR msg
            select s = (T.isPrefixOf "trying:" s
                      || T.isPrefixOf "next goal:" s)
                      && T.isSuffixOf "(user goal)" s
            pkgName =   take 1
                      . T.words
                      . T.drop 1
                      . T.dropWhile (/= ':')
        in concatMap pkgName (filter select ls)

    parseCabalOutput bs = do
        let ls = drop 1
               $ dropWhile (not . T.isPrefixOf "In order, ")
               $ linesNoCR
               $ decodeUtf8 bs
            (errs, pairs) = partitionEithers $ map parseCabalOutputLine ls
        if null errs
          then return $ Right (Map.fromList pairs)
          else error $ "The following lines from cabal-install output could \
                       \not be parsed: \n"
                       ++ T.unpack (T.intercalate "\n" errs)

    toConstraintArgs userFlagMap =
        [formatFlagConstraint package flag enabled
            | (package, fs) <- Map.toList userFlagMap
            , (flag, enabled) <- Map.toList fs]

    formatFlagConstraint package flag enabled =
        let sign = if enabled then '+' else '-'
        in
        "--constraint=" ++ unwords [packageNameString package, sign : flagNameString flag]

    -- Note the order of the Map union is important
    -- We override a package in snapshot by a src package
    flagConstraints Constraint = fmap snd (Map.union srcConstraints
                                           depConstraints)
    -- Even when using preferences we want to
    -- keep the src package flags unchanged
    -- TODO - this should be done only for manual flags.
    flagConstraints Preference = fmap snd srcConstraints


    -- An ugly parser to extract module id and flags
parseCabalOutputLine :: Text -> Either Text (PackageName, (Version, Map FlagName Bool))
parseCabalOutputLine t0 = maybe (Left t0) Right . join .  match re $ t0
    -- Sample outputs to parse:
    -- text-1.2.1.1 (latest: 1.2.2.0) -integer-simple (via: parsec-3.1.9) (new package))
    -- hspec-snap-1.0.0.0 *test (via: servant-snap-0.5) (new package)
    -- time-locale-compat-0.1.1.1 -old-locale (via: http-api-data-0.2.2) (new package))
    -- flowdock-rest-0.2.0.0 -aeson-compat *test (via: haxl-fxtra-0.0.0.0) (new package)
  where
    re = mk <$> some (psym $ not . isSpace) <*> many (lexeme reMaybeFlag)

    reMaybeFlag =
        (\s -> Just (True, s))  <$ sym '+' <*> some (psym $ not . isSpace) <|>
        (\s -> Just (False, s)) <$ sym '-' <*> some (psym $ not . isSpace) <|>
        Nothing <$ sym '*' <* some (psym $ not . isSpace) <|>
        Nothing <$ sym '(' <* few anySym <* sym ')'

    mk :: String -> [Maybe (Bool, String)] -> Maybe (PackageName, (Version, Map FlagName Bool))
    mk ident fl = do
        PackageIdentifier name version <-
            parsePackageIdentifierFromString ident
        fl' <- (traverse . traverse) parseFlagNameFromString $ catMaybes fl
        return (name, (version, Map.fromList $ map swap fl'))

    lexeme r = some (psym isSpace) *> r

getCabalConfig :: (StackM env m, HasConfig env)
               => FilePath -- ^ temp dir
               -> ConstraintType
               -> Map PackageName Version -- ^ constraints
               -> m [Text]
getCabalConfig dir constraintType constraints = do
    indices <- view $ configL.to configPackageIndices
    remotes <- mapM goIndex indices
    let cache = T.pack $ "remote-repo-cache: " ++ dir
    return $ cache : remotes ++ map goConstraint (Map.toList constraints)
  where
    goIndex index = do
        src <- configPackageIndex $ indexName index
        let dstdir = dir FP.</> T.unpack (indexNameText $ indexName index)
            -- NOTE: see https://github.com/commercialhaskell/stack/issues/2888
            -- for why we are pretending that a 01-index.tar is actually a
            -- 00-index.tar file.
            dst0 = dstdir FP.</> "00-index.tar"
            dst1 = dstdir FP.</> "01-index.tar"
        liftIO $ void $ tryIO $ do
            D.createDirectoryIfMissing True dstdir
            D.copyFile (toFilePath src) dst0
            D.copyFile (toFilePath src) dst1
        return $ T.concat
            [ "remote-repo: "
            , indexNameText $ indexName index
            , ":http://0.0.0.0/fake-url"
            ]

    goConstraint (name, version) =
        assert (not . null . versionString $ version) $
            T.concat
              [ if constraintType == Constraint
                   || name `HashSet.member` wiredInPackages
                then "constraint: "
                else "preference: "
              , T.pack $ packageNameString name
              , "=="
              , T.pack $ versionString version
              ]

setupCompiler
    :: (StackM env m, HasConfig env, HasGHCVariant env)
    => CompilerVersion 'CVWanted
    -> m (Maybe ExtraDirs)
setupCompiler compiler = do
    let msg = Just $ T.concat
          [ "Compiler version (" <> compilerVersionText compiler <> ") "
          , "required by your resolver specification cannot be found.\n\n"
          , "Please use '--install-ghc' command line switch to automatically "
          , "install the compiler or '--system-ghc' to use a suitable "
          , "compiler available on your PATH." ]

    config <- view configL
    (dirs, _, _) <- ensureCompiler SetupOpts
        { soptsInstallIfMissing  = configInstallGHC config
        , soptsUseSystem         = configSystemGHC config
        , soptsWantedCompiler    = compiler
        , soptsCompilerCheck     = configCompilerCheck config
        , soptsStackYaml         = Nothing
        , soptsForceReinstall    = False
        , soptsSanityCheck       = False
        , soptsSkipGhcCheck      = False
        , soptsSkipMsys          = configSkipMsys config
        , soptsUpgradeCabal      = Nothing
        , soptsResolveMissingGHC = msg
        , soptsSetupInfoYaml     = defaultSetupInfoYaml
        , soptsGHCBindistURL     = Nothing
        , soptsGHCJSBootOpts     = ["--clean"]
        }
    return dirs

setupCabalEnv
    :: (StackM env m, HasConfig env, HasGHCVariant env)
    => CompilerVersion 'CVWanted
    -> m (EnvOverride, CompilerVersion 'CVActual)
setupCabalEnv compiler = do
    mpaths <- setupCompiler compiler
    menv0 <- getMinimalEnvOverride
    envMap <- removeHaskellEnvVars
              <$> augmentPathMap (maybe [] edBins mpaths)
                                 (unEnvOverride menv0)
    platform <- view platformL
    menv <- mkEnvOverride platform envMap

    mcabal <- getCabalInstallVersion menv
    case mcabal of
        Nothing -> throwM SolverMissingCabalInstall
        Just version
            | version < $(mkVersion "1.24") -> $prettyWarn $
                "Installed version of cabal-install (" <>
                display version <>
                ") doesn't support custom-setup clause, and so may not yield correct results." <> line <>
                "To resolve this, install a newer version via 'stack install cabal-install'." <> line
            | version >= $(mkVersion "1.25") -> $prettyWarn $
                "Installed version of cabal-install (" <>
                display version <>
                ") is newer than stack has been tested with.  If you run into difficulties, consider downgrading." <> line
            | otherwise -> return ()

    mver <- getSystemCompiler menv (whichCompiler compiler)
    version <- case mver of
        Just (version, _) -> do
            $logInfo $ "Using compiler: " <> compilerVersionText version
            return version
        Nothing -> error "Failed to determine compiler version. \
                         \This is most likely a bug."
    return (menv, version)

-- | Merge two separate maps, one defining constraints on package versions and
-- the other defining package flagmap, into a single map of version and flagmap
-- tuples.
mergeConstraints
    :: Map PackageName v
    -> Map PackageName (Map p f)
    -> Map PackageName (v, Map p f)
mergeConstraints = Map.mergeWithKey
    -- combine entry in both maps
    (\_ v f -> Just (v, f))
    -- convert entry in first map only
    (fmap (flip (,) Map.empty))
    -- convert entry in second map only
    (\m -> if Map.null m then Map.empty
           else error "Bug: An entry in flag map must have a corresponding \
                      \entry in the version map")

-- | Given a resolver, user package constraints (versions and flags) and extra
-- dependency constraints determine what extra dependencies are required
-- outside the resolver snapshot and the specified extra dependencies.
--
-- First it tries by using the snapshot and the input extra dependencies
-- as hard constraints, if no solution is arrived at by using hard
-- constraints it then tries using them as soft constraints or preferences.
--
-- It returns either conflicting packages when no solution is arrived at
-- or the solution in terms of src package flag settings and extra
-- dependencies.
solveResolverSpec
    :: (StackM env m, HasConfig env, HasGHCVariant env)
    => Path Abs File  -- ^ stack.yaml file location
    -> [Path Abs Dir] -- ^ package dirs containing cabal files
    -> ( SnapshotDef
       , ConstraintSpec
       , ConstraintSpec) -- ^ ( resolver
                         --   , src package constraints
                         --   , extra dependency constraints )
    -> m (Either [PackageName] (ConstraintSpec , ConstraintSpec))
       -- ^ (Conflicting packages
       --    (resulting src package specs, external dependency specs))

solveResolverSpec stackYaml cabalDirs
                  (sd, srcConstraints, extraConstraints) = do
    $logInfo $ "Using resolver: " <> sdResolverName sd
    let wantedCompilerVersion = sdWantedCompilerVersion sd
    (menv, compilerVersion) <- setupCabalEnv wantedCompilerVersion
    (compilerVer, snapConstraints) <- getResolverConstraints menv (Just compilerVersion) stackYaml sd

    let -- Note - The order in Map.union below is important.
        -- We want to override snapshot with extra deps
        depConstraints = Map.union extraConstraints snapConstraints
        -- Make sure to remove any user packages from the dep constraints
        -- There are two reasons for this:
        -- 1. We do not want snapshot versions to override the sources
        -- 2. Sources may have blank versions leading to bad cabal constraints
        depOnlyConstraints = Map.difference depConstraints srcConstraints
        solver t = cabalSolver menv cabalDirs t srcConstraints depOnlyConstraints $
                     "-v" : -- TODO make it conditional on debug
                     ["--ghcjs" | whichCompiler compilerVer == Ghcjs]

    let srcNames = T.intercalate " and " $
          ["packages from " <> sdResolverName sd
              | not (Map.null snapConstraints)] ++
          [T.pack (show (Map.size extraConstraints) <> " external packages")
              | not (Map.null extraConstraints)]

    $logInfo "Asking cabal to calculate a build plan..."
    unless (Map.null depOnlyConstraints)
        ($logInfo $ "Trying with " <> srcNames <> " as hard constraints...")

    eresult <- solver Constraint
    eresult' <- case eresult of
        Left _ | not (Map.null depOnlyConstraints) -> do
            $logInfo $ "Retrying with " <> srcNames <> " as preferences..."
            solver Preference
        _ -> return eresult

    case eresult' of
        Right deps -> do
            let
                -- All src package constraints returned by cabal.
                -- Flags may have changed.
                srcs = Map.intersection deps srcConstraints
                inSnap = Map.intersection deps snapConstraints
                -- All packages which are in the snapshot but cabal solver
                -- returned versions or flags different from the snapshot.
                inSnapChanged = Map.differenceWith diffConstraints
                                                   inSnap snapConstraints
                -- Packages neither in snapshot, nor srcs
                extra = Map.difference deps (Map.union srcConstraints
                                                       snapConstraints)
                external = Map.union inSnapChanged extra

            -- Just in case.
            -- If cabal output contains versions of user packages, those
            -- versions better be the same as those in our cabal file i.e.
            -- cabal should not be solving using versions from external
            -- indices.
            let outVers  = fmap fst srcs
                inVers   = fmap fst srcConstraints
                bothVers = Map.intersectionWith (\v1 v2 -> (v1, v2))
                                                inVers outVers
            unless (outVers `Map.isSubmapOf` inVers) $ do
                let msg = "Error: user package versions returned by cabal \
                          \solver are not the same as the versions in the \
                          \cabal files:\n"
                -- TODO We can do better in formatting the message
                error $ T.unpack $ msg
                        <> showItems (map show (Map.toList bothVers))

            $logInfo $ "Successfully determined a build plan with "
                     <> T.pack (show $ Map.size external)
                     <> " external dependencies."

            return $ Right (srcs, external)
        Left x -> do
            $logInfo $ "*** Failed to arrive at a workable build plan."
            return $ Left x
    where
        -- Think of the first map as the deps reported in cabal output and
        -- the second as the snapshot packages

        -- Note: For flags we only require that the flags in cabal output be a
        -- subset of the snapshot flags. This is to avoid a false difference
        -- reporting due to any spurious flags in the build plan which will
        -- always be absent in the cabal output.
        diffConstraints
            :: (Eq v, Eq a, Ord k)
            => (v, Map k a) -> (v, Map k a) -> Maybe (v, Map k a)
        diffConstraints (v, f) (v', f')
            | (v == v') && (f `Map.isSubmapOf` f') = Nothing
            | otherwise              = Just (v, f)

-- | Given a resolver (snpashot, compiler or custom resolver)
-- return the compiler version, package versions and packages flags
-- for that resolver.
getResolverConstraints
    :: (StackM env m, HasConfig env, HasGHCVariant env)
    => EnvOverride -- ^ for running Git/Hg clone commands
    -> Maybe (CompilerVersion 'CVActual) -- ^ actually installed compiler
    -> Path Abs File
    -> SnapshotDef
    -> m (CompilerVersion 'CVActual,
          Map PackageName (Version, Map FlagName Bool))
getResolverConstraints menv mcompilerVersion stackYaml sd = do
    ls <- loadSnapshot menv mcompilerVersion (parent stackYaml) sd
    return (lsCompilerVersion ls, lsConstraints ls)
  where
    lpiConstraints lpi = (lpiVersion lpi, lpiFlags lpi)
    lsConstraints ls = Map.union
      (Map.map lpiConstraints (lsPackages ls))
      (Map.map lpiConstraints (lsGlobals ls))

-- | Finds all files with a .cabal extension under a given directory. If
-- a `hpack` `package.yaml` file exists, this will be used to generate a cabal
-- file.
-- Subdirectories can be included depending on the @recurse@ parameter.
findCabalFiles :: (MonadIO m, MonadLogger m) => Bool -> Path Abs Dir -> m [Path Abs File]
findCabalFiles recurse dir = do
    liftIO (findFiles dir isHpack subdirFilter) >>= mapM_ (hpack . parent)
    liftIO (findFiles dir isCabal subdirFilter)
  where
    subdirFilter subdir = recurse && not (isIgnored subdir)
    isHpack = (== "package.yaml")     . toFilePath . filename
    isCabal = (".cabal" `isSuffixOf`) . toFilePath

    isIgnored path = "." `isPrefixOf` dirName || dirName `Set.member` ignoredDirs
      where
        dirName = FP.dropTrailingPathSeparator (toFilePath (dirname path))

-- | Special directories that we don't want to traverse for .cabal files
ignoredDirs :: Set FilePath
ignoredDirs = Set.fromList
    [ "dist"
    ]

-- | Perform some basic checks on a list of cabal files to be used for creating
-- stack config. It checks for duplicate package names, package name and
-- cabal file name mismatch and reports any issues related to those.
--
-- If no error occurs it returns filepath and @GenericPackageDescription@s
-- pairs as well as any filenames for duplicate packages not included in the
-- pairs.
cabalPackagesCheck
    :: (StackM env m, HasConfig env, HasGHCVariant env)
     => [Path Abs File]
     -> String
     -> Maybe String
     -> m ( Map PackageName (Path Abs File, C.GenericPackageDescription)
          , [Path Abs File])
cabalPackagesCheck cabalfps noPkgMsg dupErrMsg = do
    when (null cabalfps) $
        error noPkgMsg

    relpaths <- mapM prettyPath cabalfps
    $logInfo $ "Using cabal packages:"
    $logInfo $ T.pack (formatGroup relpaths)

    (warnings, gpds) <- mapAndUnzipM readPackageUnresolved cabalfps
    zipWithM_ (mapM_ . printCabalFileWarning) cabalfps warnings

    -- package name cannot be empty or missing otherwise
    -- it will result in cabal solver failure.
    -- stack requires packages name to match the cabal file name
    -- Just the latter check is enough to cover both the cases

    let packages  = zip cabalfps gpds
        normalizeString = T.unpack . T.normalize T.NFC . T.pack
        getNameMismatchPkg (fp, gpd)
            | (normalizeString . show . gpdPackageName) gpd /= (normalizeString . FP.takeBaseName . toFilePath) fp
                = Just fp
            | otherwise = Nothing
        nameMismatchPkgs = mapMaybe getNameMismatchPkg packages

    when (nameMismatchPkgs /= []) $ do
        rels <- mapM prettyPath nameMismatchPkgs
        error $ "Package name as defined in the .cabal file must match the \
                \.cabal file name.\n\
                \Please fix the following packages and try again:\n"
                <> formatGroup rels

    let dupGroups = filter ((> 1) . length)
                            . groupSortOn (gpdPackageName . snd)
        dupAll    = concat $ dupGroups packages

        -- Among duplicates prefer to include the ones in upper level dirs
        pathlen     = length . FP.splitPath . toFilePath . fst
        getmin      = minimumBy (compare `on` pathlen)
        dupSelected = map getmin (dupGroups packages)
        dupIgnored  = dupAll \\ dupSelected
        unique      = packages \\ dupIgnored

    when (dupIgnored /= []) $ do
        dups <- mapM (mapM (prettyPath. fst)) (dupGroups packages)
        $logWarn $ T.pack $
            "Following packages have duplicate package names:\n"
            <> intercalate "\n" (map formatGroup dups)
        case dupErrMsg of
          Nothing -> $logWarn $ T.pack $
                 "Packages with duplicate names will be ignored.\n"
              <> "Packages in upper level directories will be preferred.\n"
          Just msg -> error msg

    return (Map.fromList
            $ map (\(file, gpd) -> (gpdPackageName gpd,(file, gpd))) unique
           , map fst dupIgnored)

formatGroup :: [String] -> String
formatGroup = concatMap (\path -> "- " <> path <> "\n")

reportMissingCabalFiles :: (MonadIO m, MonadThrow m, MonadLogger m)
  => [Path Abs File]   -- ^ Directories to scan
  -> Bool              -- ^ Whether to scan sub-directories
  -> m ()
reportMissingCabalFiles cabalfps includeSubdirs = do
    allCabalfps <- findCabalFiles includeSubdirs =<< getCurrentDir

    relpaths <- mapM prettyPath (allCabalfps \\ cabalfps)
    unless (null relpaths) $ do
        $logWarn $ "The following packages are missing from the config:"
        $logWarn $ T.pack (formatGroup relpaths)

-- TODO Currently solver uses a stack.yaml in the parent chain when there is
-- no stack.yaml in the current directory. It should instead look for a
-- stack yaml only in the current directory and suggest init if there is
-- none available. That will make the behavior consistent with init and provide
-- a correct meaning to a --ignore-subdirs option if implemented.

-- | Verify the combination of resolver, package flags and extra
-- dependencies in an existing stack.yaml and suggest changes in flags or
-- extra dependencies so that the specified packages can be compiled.
solveExtraDeps
    :: (StackM env m, HasEnvConfig env)
    => Bool -- ^ modify stack.yaml?
    -> m ()
solveExtraDeps modStackYaml = do
    bconfig <- view buildConfigL

    let stackYaml = bcStackYaml bconfig
    relStackYaml <- prettyPath stackYaml

    $logInfo $ "Using configuration file: " <> T.pack relStackYaml
    lp <- getLocalPackages
    let packages = lpProject lp
    let noPkgMsg = "No cabal packages found in " <> relStackYaml <>
                   ". Please add at least one directory containing a .cabal \
                   \file. You can also use 'stack init' to automatically \
                   \generate the config file."
        dupPkgFooter = "Please remove the directories containing duplicate \
                       \entries from '" <> relStackYaml <> "'."

        cabalDirs = map lpvRoot    $ Map.elems packages
        cabalfps  = map lpvCabalFP $ Map.elems packages
    -- TODO when solver supports --ignore-subdirs option pass that as the
    -- second argument here.
    reportMissingCabalFiles cabalfps True
    (bundle, _) <- cabalPackagesCheck cabalfps noPkgMsg (Just dupPkgFooter)

    let gpds              = Map.elems $ fmap snd bundle
        oldFlags          = bcFlags bconfig
        oldExtraVersions  = Map.map (gpdVersion . fst) (lpDependencies lp)
        sd                = bcSnapshotDef bconfig
        resolver          = sdResolver sd
        oldSrcs           = gpdPackages gpds
        oldSrcFlags       = Map.intersection oldFlags oldSrcs
        oldExtraFlags     = Map.intersection oldFlags oldExtraVersions

        srcConstraints    = mergeConstraints oldSrcs oldSrcFlags
        extraConstraints  = mergeConstraints oldExtraVersions oldExtraFlags

    resolverResult <- checkSnapBuildPlan (parent stackYaml) gpds (Just oldSrcFlags) sd
    resultSpecs <- case resolverResult of
        BuildPlanCheckOk flags ->
            return $ Just (mergeConstraints oldSrcs flags, Map.empty)
        BuildPlanCheckPartial {} -> do
            eres <- solveResolverSpec stackYaml cabalDirs
                              (sd, srcConstraints, extraConstraints)
            -- TODO Solver should also use the init code to ignore incompatible
            -- packages
            return $ either (const Nothing) Just eres
        BuildPlanCheckFail {} ->
            throwM $ ResolverMismatch IsSolverCmd (sdResolverName sd) (show resolverResult)

    (srcs, edeps) <- case resultSpecs of
        Nothing -> throwM (SolverGiveUp giveUpMsg)
        Just x -> return x

    mOldResolver <- view $ configL.to (fmap (projectResolver . fst) . configMaybeProject)

    let
        flags = removeSrcPkgDefaultFlags gpds (fmap snd (Map.union srcs edeps))
        versions = fmap fst edeps

        vDiff v v' = if v == v' then Nothing else Just v
        versionsDiff = Map.differenceWith vDiff
        newVersions  = versionsDiff versions oldExtraVersions
        goneVersions = versionsDiff oldExtraVersions versions

        fDiff f f' = if f == f' then Nothing else Just f
        flagsDiff  = Map.differenceWith fDiff
        newFlags   = flagsDiff flags oldFlags
        goneFlags  = flagsDiff oldFlags flags

        changed =    any (not . Map.null) [newVersions, goneVersions]
                  || any (not . Map.null) [newFlags, goneFlags]
                  || any (/= void resolver) (fmap void mOldResolver)

    if changed then do
        $logInfo ""
        $logInfo $ "The following changes will be made to "
                   <> T.pack relStackYaml <> ":"

        printResolver (fmap void mOldResolver) (void resolver)

        printFlags newFlags  "* Flags to be added"
        printDeps  newVersions   "* Dependencies to be added"

        printFlags goneFlags "* Flags to be deleted"
        printDeps  goneVersions  "* Dependencies to be deleted"

        -- TODO backup the old config file
        if modStackYaml then do
            writeStackYaml stackYaml resolver versions flags
            $logInfo $ "Updated " <> T.pack relStackYaml
        else do
            $logInfo $ "To automatically update " <> T.pack relStackYaml
                       <> ", rerun with '--update-config'"
     else
        $logInfo $ "No changes needed to " <> T.pack relStackYaml

    where
        indentLines t = T.unlines $ fmap ("    " <>) (T.lines t)

        printResolver mOldRes res = do
            forM_ mOldRes $ \oldRes ->
                when (res /= oldRes) $ do
                    $logInfo $ T.concat
                        [ "* Resolver changes from "
                        , resolverRawName oldRes
                        , " to "
                        , resolverRawName res
                        ]

        printFlags fl msg = do
            unless (Map.null fl) $ do
                $logInfo $ T.pack msg
                $logInfo $ indentLines $ decodeUtf8 $ Yaml.encode
                                       $ object ["flags" .= fl]

        printDeps deps msg = do
            unless (Map.null deps) $ do
                $logInfo $ T.pack msg
                $logInfo $ indentLines $ decodeUtf8 $ Yaml.encode $ object
                        ["extra-deps" .= map fromTuple (Map.toList deps)]

        writeStackYaml path res deps fl = do
            let fp = toFilePath path
            obj <- liftIO (Yaml.decodeFileEither fp) >>= either throwM return
            -- Check input file and show warnings
            _ <- loadConfigYaml (parseProjectAndConfigMonoid (parent path)) path
            let obj' =
                    HashMap.insert "extra-deps"
                        (toJSON $ map fromTuple $ Map.toList deps)
                  $ HashMap.insert ("flags" :: Text) (toJSON fl)
                  $ HashMap.insert ("resolver" :: Text) (toJSON res) obj
            liftIO $ Yaml.encodeFile fp obj'

        giveUpMsg = concat
            [ "    - Update external packages with 'stack update' and try again.\n"
            , "    - Tweak " <> toFilePath stackDotYaml <> " and try again\n"
            , "        - Remove any unnecessary packages.\n"
            , "        - Add any missing remote packages.\n"
            , "        - Add extra dependencies to guide solver.\n"
            , "        - Adjust resolver.\n"
            ]

prettyPath
    :: forall r t m. (MonadIO m, RelPath (Path r t) ~ Path Rel t, AnyPath (Path r t))
    => Path r t -> m String
prettyPath path = do
    eres <- liftIO $ try $ makeRelativeToCurrentDir path
    return $ case eres of
        Left (_ :: PathParseException) -> toFilePath path
        Right res -> toFilePath (res :: Path Rel t)
