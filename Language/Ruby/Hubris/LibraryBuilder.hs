
{-# LANGUAGE TemplateHaskell, QuasiQuotes, ScopedTypeVariables #-}
module Language.Ruby.Hubris.LibraryBuilder (generateLib) where
import Language.Ruby.Hubris
import Language.Haskell.Interpreter
-- import Language.Haskell.Meta.QQ.HsHere
import Language.Ruby.Hubris.GHCBuild

import List(intersperse)
import Data.List(intercalate)
import qualified Debug.Trace
import Control.Applicative
import Control.Monad
import Control.Monad.Error.Class
import Data.Maybe(catMaybes)

import GHC(parseStaticFlags, noLoc)
import System.IO(hPutStr, hClose, openTempFile)
import System.Exit
import Language.Ruby.Hubris.ZCode (zenc,Zname(..))

type Filename = String
dotrace a b = b

-- weirdly, mapMaybeM doesn't exist.
mapMaybeM :: (Functor m, Monad m) => (a -> m (Maybe b)) -> [a] -> m [b]
mapMaybeM func ls  = catMaybes <$> (sequence $ map func ls)

generateLib :: Filename -> [Filename] -> ModuleName -> [String] -> [String] -> IO (Either Filename String)
generateLib libFile sources moduleName buildArgs packages = do
  -- set up the static args once  
  GHC.parseStaticFlags $ map noLoc $ map ("-package "++) ("hubris":packages)

  s <- generateSource sources moduleName
  case s of
     Right (c,mod) -> do bindings <- withTempFile "hubris_interface_XXXXX.c" c
                         ghcBuild libFile mod ("Language.Ruby.Hubris.Exports." ++ moduleName) sources [bindings] buildArgs
     Left x -> return . Left $ show x
                                            
type Funcname = String               
type Wrapper = String



arity :: String -> InterpreterT IO (Maybe Int)
arity func = arity' 0 func
  where cutoff = 20                             
        arity' tries func
          | tries > cutoff = return Nothing
          | otherwise = do ok <- typeChecks (func ++ " `asTypeOf` (\\_ -> undefined)")
                           if ok
                             then arity' (1+tries) ("(" ++ func ++ " undefined)")
                             else return (Just tries)

-- ok, let's see if we can come up with an expression of the right type
exportable ::  String -> String -> InterpreterT IO (Maybe (Funcname, Int, Wrapper))
exportable moduleName func = do args <- arity qualName
                                case args of
                                  Nothing -> return Nothing
                                  Just i -> do let wrapped = genWrapper (qualName,i)
                                               typeChecks (wrapped ++ " = " ++ rubyVal) >>= \x -> (return $ guard x >> return (func,i,wrapped))
  where qualName = moduleName ++ "." ++ func
        rubyVal = "(fromIntegral $ fromEnum $ Language.Ruby.Hubris.Binding.RUBY_Qtrue)"
        
                                     

generateSource :: [Filename] ->   -- optional haskell source to load into the interpreter
                   ModuleName ->   -- name of the module to build a wrapper for
                   IO (Either InterpreterError (String,String))
generateSource sources moduleName = runInterpreter $ do
         loadModules sources
         setImportsQ $ [(mod,Just mod) | mod <- ["Language.Ruby.Hubris","Language.Ruby.Hubris.Binding",moduleName]]
         funcs <- getFunctions moduleName 
         say ("Candidates: " ++ show funcs)
         exports :: [(Funcname, Int,  Wrapper)] <- mapMaybeM (exportable moduleName) funcs
         say ("Exportable: " ++ show exports)
         return (undefined, undefined)
         return (genC [(a,b) | (a,b,_) <- exports] (zenc moduleName),
                 unlines (haskellBoilerplate moduleName:[wrapper | (_,_,wrapper) <- exports]))
                          
getFunctions moduleName = (\ x -> [a |Fun a <- x]) <$> getModuleExports moduleName


genC :: [(String,Int)] -> Zname -> String
genC exports (Zname zmoduleName) = unlines $ 
         ["#include <stdio.h>"
          ,"#include <stdlib.h>"
          ,"#define HAVE_STRUCT_TIMESPEC 1"
          ,"#include <ruby.h>"
          ,"#define DEBUG 1"
          ,"#ifdef DEBUG"
          ,"#define eprintf printf"
          ,"#else"
          ,"int eprintf(const char *f, ...){}"
          ,"#endif"
         ] ++
--         map (("VALUE hubrish_"++) . (++"(VALUE);")) exports ++
--         map (("VALUE hubrish_"++) . (++"(VALUE);")) exports ++
         map cWrapper exports ++
         ["extern void safe_hs_init();"
         ,"extern VALUE Exports;"
         ,"void Init_" ++ zmoduleName ++ "(){"
         ,"  eprintf(\"loading " ++ zmoduleName ++ "\\n\");"
         ,"  VALUE Fake = Qnil;"
         ,"  safe_hs_init();"
         ,"  Fake = rb_define_module_under(Exports, \"" ++ zmoduleName ++ "\");"
         ] ++ map cDef exports ++  ["}"]
  where
    cWrapper :: (String,Int) -> String
    cWrapper (f,arity) = let res = unlines ["VALUE " ++ f ++ "(VALUE mod, VALUE v){"
                                         ,"  eprintf(\""++f++" has been called\\n\");"
                               -- also needs to curry on the ruby side

                               -- v is actually an array now, so we need to stash each element in
                               -- a nested haskell tuple. for the moment, let's just take the first one.
                               
                                         ,"  VALUE res = hubrish_" ++ f ++ intercalate "," ["(rb_ary_entry(v," ++ show i ++ ")"| i<- [0..(arity-1)]]
                                         ,"  eprintf(\"hubrish "++f++" has been called\\n\");"
--                              ,"  return res;"
                                         ,"  if (rb_obj_is_kind_of(res,rb_eException)) {"
                                         ,"    eprintf(\""++f++" has provoked an exception\\n\");"                               
                                         ,"    rb_exc_raise(res);"
                                         ,"  } else {"
                                         ,"    eprintf(\"returning from "++f++"\\n\");"
                                         ,"    return res;"
                                         ,"  }"
                                         ,"}"]
                       in res 
                                    

    cDef :: (String,Int) -> String
    -- adef f =  "  eprintf(\"Defining |" ++ f  ++ "|\\n\");\n" ++ "rb_define_method(Fake, \"" ++ f ++"\","++ f++", 1);"
    cDef (f,_arity) =  "  eprintf(\"Defining |" ++ f  ++ "|\\n\");\n" ++ "rb_define_method(Fake, \"" ++ f ++"\","++ f++", -2);"

haskellBoilerplate moduleName = unlines ["{-# LANGUAGE ForeignFunctionInterface, ScopedTypeVariables #-}", 
                                         "module Language.Ruby.Hubris.Exports." ++ moduleName ++ " where",
                                         "import Language.Ruby.Hubris",
                                         "import qualified Prelude as P()",
                                         "import Data.Tuple (uncurry)",
                                         "import qualified " ++ moduleName]



-- wrapper = func ++ " b = (Language.Ruby.Hubris.wrap " ++ moduleName ++ "." ++  func ++ ") b", 
genWrapper (func,arity) = unlines $ [func ++ " :: " ++ myType
                                            ,func ++ unwords symbolArgs ++ " = " ++ defHask 
                                            ,"foreign export ccall \"hubrish_" ++  func ++ "\" " ++ func ++ " :: " ++ myType]
  where myType = intercalate "->" (take arity $ repeat " Value ")
        -- mark's patented gensyms. just awful.
        symbolArgs = take arity $ map ( \ x -> "fake_arg_symbol_"++[x]) ['a' .. 'z']
        defHask = "unsafePerformIO $ do r <- try $ evaluate $ toRuby $ case func " ++ 
                  unwords (map (\ x -> "(toHaskell " ++ x ++ ")") symbolArgs) ++ " of\n" ++
                  unlines ["  Left (e::SomeException) -> createException (show e) `traces` \"died in haskell\"",
                           "  Right a -> return a"]
 
say :: String -> InterpreterT IO ()
say = liftIO . putStrLn

-- Local Variables:
-- compile-command: "cd ../../../; ./Setup build"
-- End:
