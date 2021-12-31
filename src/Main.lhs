-----------------------------------------------------------------------------
The main driver.

(c) 1993-2003 Andy Gill, Simon Marlow
GLR amendments (c) University of Durham, Ben Medlock 2001
-----------------------------------------------------------------------------

> module Main (main) where

Path settings auto-generated by Cabal:

> import Paths_happy

> import Happy.Grammar
> import Happy.Frontend
> import Happy.Frontend.AbsSyn
> import Happy.Frontend.Mangler
> import Happy.Frontend.PrettyGrammar
> import Happy.Backend.LALR
> import Happy.Backend.LALR.Target (Target(..))
> import Happy.Backend.LALR.ProduceCode (produceParser)
> import Happy.Backend.GLR
> import Happy.Backend.GLR.ProduceCode
> import Happy.Tabular
> import Happy.Tabular.Info (genInfoFile)

> import System.Console.GetOpt
> import Control.Monad ( liftM, when )
> import System.Environment
> import System.Exit (exitWith, ExitCode(..))
> import Data.Char
> import System.IO
> import Data.List( isSuffixOf )
> import Data.Version ( showVersion )

> main :: IO ()
> main = do

Read and parse the CLI arguments.

>       args <- getArgs
>       main2 args

> main2 :: [String] -> IO ()
> main2 args =

Read and parse the CLI arguments.

>       case getOpt Permute argInfo (constArgs ++ args) of
>               (cli,_,[]) | DumpVersion `elem` cli ->
>                  bye copyright
>               (cli,_,[]) | DumpHelp `elem` cli -> do
>                  prog <- getProgramName
>                  bye (usageInfo (usageHeader prog) argInfo)
>               (cli,_,_) | OptDebugParser `elem` cli
>                        && OptArrayTarget `notElem` cli -> do
>                  die "Cannot use debugging without -a\n"
>               (cli,[fl_name],[]) ->
>                  runParserGen cli fl_name
>               (_,_,errors) -> do
>                  prog <- getProgramName
>                  die (concat errors ++
>                       usageInfo (usageHeader prog) argInfo)

>  where
>    runParserGen cli fl_name = do

Open the file.

>       fl <- readFile fl_name
>       (name, file) <- case fileNameAndType fl_name of
>                         Nothing -> die ("`" ++ fl_name ++ "' does not end in `.y' or `.ly'\n")
>                         Just (name, Y) -> return (name, fl)
>                         Just (name, LY) -> return (name, deLitify fl)

Parse, using bootstrapping parser.

>       (BookendedAbsSyn hd abssyn tl) <- case parseYFileContents file of
>               Left err -> die (fl_name ++ ':' : err)
>               Right bas -> return bas

Mangle the syntax into something useful.

>       g <- case {-# SCC "Mangler" #-} mangler fl_name abssyn of
>               Left  s -> die (unlines s ++ "\n")
>               Right g -> return g

>       optPrint cli DumpMangle $ putStr $ show g

>       let select_reductions | OptGLR `elem` cli = select_all_reductions
>                             | otherwise         = select_first_reduction

>       let tables      = genTables select_reductions g
>           sets        = lr0items tables
>           lainfo      = (la_prop tables, la_spont tables)
>           la          = lookaheads tables
>           goto        = gotoTable tables
>           action      = actionTable tables
>           (conflictArray,(sr,rr)) = conflicts tables

Debug output

>       optPrint cli DumpLR0    $ putStr $ show sets
>       optPrint cli DumpAction $ putStr $ show action
>       optPrint cli DumpGoto   $ putStr $ show goto
>       optPrint cli DumpLA     $ putStr $ show lainfo
>       optPrint cli DumpLA     $ putStr $ show la

Report any unused rules and terminals

>       let (unused_rules, unused_terminals) = redundancies tables
>       when (not (null unused_rules))
>          (hPutStrLn stderr ("unused rules: " ++ show (length unused_rules)))
>       when (not (null unused_terminals))
>          (hPutStrLn stderr ("unused terminals: " ++ show (length unused_terminals)))

Print out the info file.

>       info_filename <- getInfoFileName name cli
>       let info = genInfoFile
>                       (map fst sets)
>                       g
>                       action
>                       goto
>                       (token_specs g)
>                       conflictArray
>                       fl_name
>                       unused_rules
>                       unused_terminals
>                       version
>       case info_filename of
>         Just s  -> do
>           writeFile s info
>           hPutStrLn stderr ("Grammar info written to: " ++ s)
>         Nothing -> return ()


Pretty print the AbsSyn.

>       pretty_filename <- getPrettyFileName name cli
>       case pretty_filename of
>         Just s   -> do
>           let out = render (ppAbsSyn abssyn)
>           writeFile s out
>           hPutStrLn stderr ("Production rules written to: " ++ s)
>         Nothing  -> return ()

Report any conflicts in the grammar.

>       case expect g of
>         Just n | n == sr && rr == 0 -> return ()
>         Just _ | rr > 0 ->
>                 die ("The grammar has reduce/reduce conflicts.\n" ++
>                      "This is not allowed when an expect directive is given\n")
>         Just _ ->
>                die ("The grammar has " ++ show sr ++
>                     " shift/reduce conflicts.\n" ++
>                     "This is different from the number given in the " ++
>                     "expect directive\n")
>         _ -> do

>          (if sr /= 0
>              then hPutStrLn stderr ("shift/reduce conflicts:  " ++ show sr)
>              else return ())

>          (if rr /= 0
>              then hPutStrLn stderr ("reduce/reduce conflicts: " ++ show rr)
>              else return ())




Now, let's get on with generating the parser.  Firstly, find out what kind
of code we should generate, and where it should go:

>       target      <- getTarget cli
>       outfilename <- getOutputFileName fl_name cli
>       opt_coerce  <- getCoerce target cli
>       opt_strict  <- getStrict cli
>       opt_array   <- getArray cli
>       opt_ghc     <- getGhc cli
>       opt_debug   <- getDebug cli

Add any special options or imports required by the parsing machinery.

>       let
>           header = Just $
>             (case hd of Just s -> s; Nothing -> "")
>             ++ importsToInject opt_ghc opt_debug


%---------------------------------------
Branch off to GLR parser production

>       let glr_decode | OptGLR_Decode `elem` cli = TreeDecode
>                      | otherwise                = LabelDecode
>           filtering  | OptGLR_Filter `elem` cli = UseFiltering
>                      | otherwise                = NoFiltering
>           ghc_exts   | OptGhcTarget `elem` cli  = UseGhcExts
>                                                   (importsToInject opt_ghc opt_debug)

Unlike below, don't always pass CPP, because only one of the files needs it.

>                                                   (langExtsToInject opt_ghc)
>                      | otherwise                = NoGhcExts
>       if OptGLR `elem` cli
>         then do
>           template' <- getTemplate glrBackendDataDir cli
>           let basename  = takeWhile (/='.') outfilename
>           let tbls  = (action,goto)
>           (parseName,_,_,_) <- case starts g of
>                                [s] -> return s
>                                s:_ -> do
>                                          putStrLn "GLR-Happy doesn't support multiple start points (yet)"
>                                          putStrLn "Defaulting to first start point."
>                                          return s
>                                [] -> error "produceGLRParser: []"
>           base <- readFile (baseTemplate template')
>           lib <- readFile (libTemplate template')
>           let (dat, parser) = produceGLRParser
>                 (base, lib)   -- templates
>                 basename      -- basename of specified output file name
>                 tbls          -- action table (:: ActionTable)
>                               -- goto table (:: GotoTable)
>                 parseName
>                 header        -- header from grammar spec
>                 tl            -- trailer from grammar spec
>                 (opt_debug, (glr_decode,filtering,ghc_exts))
>                               -- controls decoding code-gen
>                 g             -- grammar object
>           writeFile (basename ++ "Data.hs") dat
>           writeFile (basename ++ ".hs") parser

>         else do


%---------------------------------------
Resume normal (ie, non-GLR) processing

>           template'   <- getTemplate lalrBackendDataDir cli
>           let
>               template = template' ++ "/HappyTemplate.hs"

Read in the template file for this target:

>           templ <- readFile template

and generate the code.

>           magic_name <- getMagicName cli
>           let
>               outfile = produceParser
>                           g
>                           action
>                           goto

CPP is needed in all cases with unified template

>                           ("CPP" : langExtsToInject opt_ghc)
>                           header
>                           tl
>                           target
>                           opt_coerce
>                           opt_ghc
>                           opt_strict

>               defines' = defines opt_debug opt_array opt_ghc opt_coerce

>           (if outfilename == "-" then putStr else writeFile outfilename)
>                   (magicFilter magic_name (outfile ++ defines' ++ templ))

Successfully Finished.

-----------------------------------------------------------------------------

> getProgramName :: IO String
> getProgramName = liftM (`withoutSuffix` ".bin") getProgName
>    where str' `withoutSuffix` suff
>             | suff `isSuffixOf` str' = take (length str' - length suff) str'
>             | otherwise              = str'

> bye :: String -> IO a
> bye s = putStr s >> exitWith ExitSuccess

> die :: String -> IO a
> die s = hPutStr stderr s >> exitWith (ExitFailure 1)

> dieHappy :: String -> IO a
> dieHappy s = getProgramName >>= \prog -> die (prog ++ ": " ++ s)

> optPrint :: [CLIFlags] -> CLIFlags -> IO () -> IO ()
> optPrint cli pass io =
>       when (elem pass cli) (putStr "\n---------------------\n" >> io)

> constArgs :: [String]
> constArgs = []

------------------------------------------------------------------------------
The command line arguments.

> data CLIFlags =
>                 DumpMangle
>               | DumpLR0
>               | DumpAction
>               | DumpGoto
>               | DumpLA
>               | DumpVersion
>               | DumpHelp
>               | OptInfoFile (Maybe String)
>               | OptPrettyFile (Maybe String)
>               | OptTemplate String
>               | OptMagicName String
>
>               | OptGhcTarget
>               | OptArrayTarget
>               | OptUseCoercions
>               | OptDebugParser
>               | OptStrict
>               | OptOutputFile String
>               | OptGLR
>               | OptGLR_Decode
>               | OptGLR_Filter
>  deriving Eq

> argInfo :: [OptDescr CLIFlags]
> argInfo  = [
>    Option ['o'] ["outfile"] (ReqArg OptOutputFile "FILE")
>       "write the output to FILE (default: file.hs)",
>    Option ['i'] ["info"] (OptArg OptInfoFile "FILE")
>       "put detailed grammar info in FILE",
>    Option ['p'] ["pretty"] (OptArg OptPrettyFile "FILE")
>       "pretty print the production rules to FILE",
>    Option ['t'] ["template"] (ReqArg OptTemplate "DIR")
>       "look in DIR for template files",
>    Option ['m'] ["magic-name"] (ReqArg OptMagicName "NAME")
>       "use NAME as the symbol prefix instead of \"happy\"",
>    Option ['s'] ["strict"] (NoArg OptStrict)
>       "evaluate semantic values strictly (experimental)",
>    Option ['g'] ["ghc"]    (NoArg OptGhcTarget)
>       "use GHC extensions",
>    Option ['c'] ["coerce"] (NoArg OptUseCoercions)
>       "use type coercions (only available with -g)",
>    Option ['a'] ["array"] (NoArg OptArrayTarget)
>       "generate an array-based parser",
>    Option ['d'] ["debug"] (NoArg OptDebugParser)
>       "produce a debugging parser (only with -a)",
>    Option ['l'] ["glr"] (NoArg OptGLR)
>       "Generate a GLR parser for ambiguous grammars",
>    Option ['k'] ["decode"] (NoArg OptGLR_Decode)
>       "Generate simple decoding code for GLR result",
>    Option ['f'] ["filter"] (NoArg OptGLR_Filter)
>       "Filter the GLR parse forest with respect to semantic usage",
>    Option ['?'] ["help"] (NoArg DumpHelp)
>       "display this help and exit",
>    Option ['V','v'] ["version"] (NoArg DumpVersion)   -- ToDo: -v is deprecated
>       "output version information and exit"

Various debugging/dumping options...

>    ,
>    Option [] ["ddump-mangle"] (NoArg DumpMangle)
>       "Dump mangled input",
>    Option [] ["ddump-lr0"] (NoArg DumpLR0)
>       "Dump LR0 item sets",
>    Option [] ["ddump-action"] (NoArg DumpAction)
>       "Dump action table",
>    Option [] ["ddump-goto"] (NoArg DumpGoto)
>       "Dump goto table",
>    Option [] ["ddump-lookaheads"] (NoArg DumpLA)
>       "Dump lookahead info"

>    ]

------------------------------------------------------------------------------
Extract various command-line options.

> getTarget :: [CLIFlags] -> IO Target
> getTarget cli = case [ t | (Just t) <- map optToTarget cli ] of
>                       (t:ts) | all (==t) ts -> return t
>                       []  -> return TargetHaskell
>                       _   -> dieHappy "multiple target options\n"
>  where
>    optToTarget OptArrayTarget = Just TargetArrayBased
>    optToTarget _              = Nothing

> getOutputFileName :: String -> [CLIFlags] -> IO String
> getOutputFileName ip_file cli
>       = case [ s | (OptOutputFile s) <- cli ] of
>               []   -> return (base ++ ".hs")
>                        where (base, _ext) = break (== '.') ip_file
>               f:fs -> return (last (f:fs))

> getInfoFileName :: String -> [CLIFlags] -> IO (Maybe String)
> getInfoFileName base cli
>       = case [ s | (OptInfoFile s) <- cli ] of
>               []      -> return Nothing
>               [f]     -> case f of
>                               Nothing -> return (Just (base ++ ".info"))
>                               Just j  -> return (Just j)
>               _many   -> dieHappy "multiple --info/-i options\n"

> getPrettyFileName :: String -> [CLIFlags] -> IO (Maybe String)
> getPrettyFileName base cli
>       = case [ s | (OptPrettyFile s) <- cli ] of
>               []      -> return Nothing
>               [f]     -> case f of
>                               Nothing -> return (Just (base ++ ".grammar"))
>                               Just j  -> return (Just j)
>               _many   -> dieHappy "multiple --pretty/-p options\n"

> getTemplate :: IO String -> [CLIFlags] -> IO String
> getTemplate def cli
>       = case [ s | (OptTemplate s) <- cli ] of
>               []         -> def
>               f:fs       -> return (last (f:fs))

> getMagicName :: [CLIFlags] -> IO (Maybe String)
> getMagicName cli
>       = case [ s | (OptMagicName s) <- cli ] of
>               []         -> return Nothing
>               f:fs       -> return (Just (map toLower (last (f:fs))))

> getCoerce :: Target -> [CLIFlags] -> IO Bool
> getCoerce _target cli
>       = if OptUseCoercions `elem` cli
>            then if OptGhcTarget `elem` cli
>                       then return True
>                       else dieHappy ("-c/--coerce may only be used " ++
>                                      "in conjunction with -g/--ghc\n")
>            else return False

> getArray :: [CLIFlags] -> IO Bool
> getArray cli = return (OptArrayTarget `elem` cli)

> getGhc :: [CLIFlags] -> IO Bool
> getGhc cli = return (OptGhcTarget `elem` cli)

> getStrict :: [CLIFlags] -> IO Bool
> getStrict cli = return (OptStrict `elem` cli)

> getDebug :: [CLIFlags] -> IO Bool
> getDebug cli = return (OptDebugParser `elem` cli)

------------------------------------------------------------------------------

> copyright :: String
> copyright = unlines [
>  "Happy Version " ++ showVersion version ++ " Copyright (c) 1993-1996 Andy Gill, Simon Marlow (c) 1997-2005 Simon Marlow","",
>  "Happy is a Yacc for Haskell, and comes with ABSOLUTELY NO WARRANTY.",
>  "This program is free software; you can redistribute it and/or modify",
>  "it under the terms given in the file 'LICENSE' distributed with",
>  "the Happy sources."]

> usageHeader :: String -> String
> usageHeader prog = "Usage: " ++ prog ++ " [OPTION...] file\n"

-----------------------------------------------------------------------------
