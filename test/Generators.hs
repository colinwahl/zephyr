{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns   #-}
module Generators where

import Data.List (foldl')
import Data.String (IsString (..))
import Test.QuickCheck

import Language.PureScript.Names (Ident (..), ModuleName (..), ProperName (..), Qualified (..), moduleNameFromString)
import Language.PureScript.PSString (PSString)
import Language.PureScript.AST.SourcePos (SourceSpan (..), SourcePos (..))
import Language.PureScript.AST (Literal (..))
import Language.PureScript.CoreFn (Ann, Bind (..), Binder (..), CaseAlternative (..), Expr (..), Guard, ssAnn)

import qualified Language.PureScript.DCE.Constants as C

ann :: Ann
ann = ssAnn (SourceSpan "src/Test.purs" (SourcePos 0 0) (SourcePos 0 0))

genPSString :: Gen PSString
genPSString = fromString <$> elements
  ["a", "b", "c", "d", "value0"]

genProperName :: Gen (ProperName a)
genProperName = ProperName <$> elements
  ["A", "B", "C", "D", "E"]

genIdent :: Gen Ident
genIdent = Ident <$> elements
  ["value0", "value1", "value2"]

unusedIdents :: [Ident]
unusedIdents =
  Ident <$> ["u1", "u2", "u3", "u4", "u5"]

genUnusedIdent :: Gen Ident
genUnusedIdent = elements unusedIdents

genModuleName :: Gen ModuleName
genModuleName = elements
  [ moduleNameFromString "Data.Eq"
  , moduleNameFromString "Data.Array"
  , moduleNameFromString "Data.Maybe"
  , C.semigroup
  , C.unsafeCoerce
  , C.unit
  , C.semiring
  ]

genQualifiedIdent :: Gen (Qualified Ident)
genQualifiedIdent = oneof
  [ Qualified <$> liftArbitrary genModuleName <*> genIdent
  , return (Qualified (Just C.unit) (Ident "unit"))
  , return (Qualified (Just C.semiring) (Ident "add"))
  , return (Qualified (Just C.semiring) (Ident "semiringInt"))
  , return (Qualified (Just C.semiring) (Ident "semiringUnit"))
  , return (Qualified (Just C.maybeMod) (Ident "Just"))
  , return (Qualified (Just C.eqMod) (Ident "eq"))
  , return (Qualified (Just C.ring) (Ident "negate"))
  , return (Qualified (Just C.ring) (Ident "ringNumber"))
  , return (Qualified (Just C.ring) (Ident "unitRing"))
  ]

genQualified :: Gen a -> Gen (Qualified a)
genQualified gen = Qualified <$> liftArbitrary genModuleName <*> gen

genLiteral :: Gen (Literal (Expr Ann))
genLiteral = oneof
  [ NumericLiteral <$> arbitrary
  , StringLiteral  <$> genPSString
  , CharLiteral    <$> arbitrary
  , BooleanLiteral <$> arbitrary
  , ArrayLiteral . map unPSExpr <$> arbitrary
  , ObjectLiteral . map (\(k, v) -> (fromString k, unPSExpr v)) <$> arbitrary
  ]

genLiteral' :: Gen (Expr Ann)
genLiteral' = oneof
  [ Literal ann . NumericLiteral <$> arbitrary
  , Literal ann . StringLiteral <$> genPSString
  , Literal ann . BooleanLiteral <$> arbitrary
  , Literal ann . CharLiteral <$> arbitrary
  ]

genExpr :: Gen (Expr Ann)
genExpr = unPSExpr <$> arbitrary

genCaseAlternative :: Gen (CaseAlternative Ann)
genCaseAlternative = sized $ \n -> 
  CaseAlternative <$> vectorOf n genBinder <*> genCaseAlternativeResult n
  where
  genCaseAlternativeResult :: Int -> Gen (Either [(Guard Ann, Expr Ann)] (Expr Ann))
  genCaseAlternativeResult n = oneof
    [ Left  <$> vectorOf n ((,) <$> resize n genExpr <*> resize n genExpr)
    , Right <$> resize n genExpr
    ]

newtype PSBinder = PSBinder { unPSBinder :: Binder Ann }
  deriving Show

instance Arbitrary PSBinder where
  arbitrary = resize 5 $ PSBinder <$> sized go
    where
    go :: Int -> Gen (Binder Ann)
    go 0 = oneof
      [ return $ NullBinder ann
      , VarBinder ann <$> genIdent
      ]
    go n = frequency
      [ (1, return $ NullBinder ann)
      , (2, LiteralBinder ann . ArrayLiteral  <$> listOf (go (n - 1)))
      , (2, LiteralBinder ann . ObjectLiteral <$> listOf ((,) <$> genPSString <*> (go (n - 1))))
      , (3, ConstructorBinder ann <$> genQualified genProperName <*> genQualified genProperName <*> listOf (go (n - 1)))
      , (3, NamedBinder ann <$> genIdent <*> (go (n - 1)))
      ]

  shrink (PSBinder (LiteralBinder _ (ArrayLiteral bs))) =
    (PSBinder . LiteralBinder ann . ArrayLiteral . map unPSBinder
    <$> (shrinkList shrink (PSBinder <$> bs)))
    ++ map PSBinder bs
  shrink (PSBinder (LiteralBinder _ (ObjectLiteral o))) =
    (PSBinder . LiteralBinder ann . ObjectLiteral
    <$> shrinkList (\(n, b) -> (n,) . unPSBinder <$> shrink (PSBinder b)) o)
    ++ map (PSBinder . snd) o
  shrink (PSBinder (ConstructorBinder _ tn cn bs)) =
    (PSBinder . ConstructorBinder ann tn cn . map unPSBinder
    <$> (shrinkList shrink (PSBinder <$> bs)))
    ++ map PSBinder bs
  shrink (PSBinder (NamedBinder _ n b)) =
    PSBinder b
    : (PSBinder . NamedBinder ann n . unPSBinder <$> shrink (PSBinder b))
  shrink _ = []

genBinder :: Gen (Binder Ann)
genBinder = unPSBinder <$> arbitrary

prop_binderDistribution :: PSBinder -> Property
prop_binderDistribution (PSBinder c) =
    classify True (show . depth $ c)
  $ tabulate "Binders" (cls c) True
  where
  cls NullBinder{}                 = ["NullBinder"]
  cls LiteralBinder{}              = ["LiteralBinder"]
  cls VarBinder{}                  = ["VarBinder"]
  cls (ConstructorBinder _ _ _ bs) = "ConstructorBinder" : concatMap cls bs
  cls (NamedBinder _ _ b)          = "NamedBinder" : cls b

  depth :: Binder a -> Int
  depth NullBinder{}                        = 1
  depth (LiteralBinder _ (ArrayLiteral bs)) = foldr (\b x -> depth b `max` x) 1 bs + 1 
  depth (LiteralBinder _ (ObjectLiteral o)) = foldr (\(_, b) x -> depth b `max` x) 0 o + 1
  depth LiteralBinder{}                     = 1
  depth VarBinder{}                         = 1
  depth (ConstructorBinder _ _ _ bs)        = foldr (\b x -> depth b `max` x) 1 bs + 1
  depth (NamedBinder _ _ b)                 = depth b

genBind :: Gen (Bind Ann)
genBind = frequency
  [ (3, NonRec ann <$> gen  <*> genExpr)
  , (1, Rec <$> listOf ((\i e -> ((ann, i), e)) <$> gen <*> genExpr))
  ]
  where
  gen = frequency [(3, genIdent), (2, genUnusedIdent)]

newtype PSExpr a = PSExpr { unPSExpr :: Expr a }
  deriving Show

-- Generate simple curried functions
genApp :: Gen (PSExpr Ann)
genApp =
  (\x y -> PSExpr $ App ann x y)
    <$> frequency
        [ (1, unPSExpr <$> genApp)
        , (2, Var ann <$> genQualifiedIdent)
        ]
    <*> frequency
        [ (2, Var ann <$> genQualifiedIdent)
        , (3, genLiteral')
        ]

instance Arbitrary (PSExpr Ann) where
  arbitrary = resize 5 $ sized go
    where
    go :: Int -> Gen (PSExpr Ann)
    go 0 = oneof
      [ PSExpr . Literal ann <$> genLiteral
      , fmap PSExpr $ Constructor ann <$> genProperName <*> genProperName <*> listOf genIdent
      , fmap PSExpr $ Var ann <$> genQualifiedIdent
      ]
    go n = frequency
      [ (3, PSExpr . Literal ann <$> genLiteral)
      , (3, fmap PSExpr $ Constructor ann <$> genProperName <*> genProperName <*> listOf genIdent)
      , (3, fmap PSExpr $ Var ann <$> genQualifiedIdent)
      , (4, fmap PSExpr $ Accessor ann <$> genPSString <*> (unPSExpr <$> go (n - 1)))
      , (1, fmap PSExpr $ ObjectUpdate ann <$> genExpr <*> resize (max 3 (n - 1)) (listOf ((,) <$> genPSString <*> (unPSExpr <$> go (n - 1)))))
      , (2, fmap PSExpr $ Abs ann <$> genIdent <*> (unPSExpr <$> go (n - 1)))
      , (1, fmap PSExpr $ App ann <$> (unPSExpr <$> go (n - 1)) <*> (unPSExpr <$> go (n - 1)))
      , (4, genApp)
      , (1, fmap PSExpr $ Case ann <$> resize (max 3 (n `div` 2)) (listOf (unPSExpr <$> go (n - 1))) <*> resize (max 2 (n `div` 2)) (listOf (resize (n - 1) genCaseAlternative)))
      , (4, fmap PSExpr $ Let ann <$> listOf genBind <*> (unPSExpr <$> go (n - 1)))
      ]

  shrink (PSExpr expr) = map PSExpr $ go expr
    where
    go :: Expr Ann -> [Expr Ann]
    go (Literal ann' (ArrayLiteral es)) =
      (Literal ann' . ArrayLiteral <$> shrinkList shrinkExpr es)
      ++ es
    go (Literal ann' (ObjectLiteral o)) =
      (Literal ann' . ObjectLiteral
      <$> shrinkList (\(n, e) -> (n,) <$> shrinkExpr e) o)
      ++ map snd o
    go (Accessor ann' n e) =
      e : (Accessor ann' n <$> shrinkExpr e)
    go (ObjectUpdate ann' e es) =
      e : map snd es
      ++
        [ ObjectUpdate ann' e' es'
        | e'  <- shrinkExpr e
        , es' <- shrinkList (\(n, f) -> map (n,) $ shrinkExpr f) es
        ]
    go (Abs ann' n e) =
      let es = shrinkExpr e
      in e : es ++ map (Abs ann' n) es
    go (App ann' e f) =
      e : f : [ App ann' e' f' | e' <- shrinkExpr e, f' <- shrinkExpr f ]
    go Var{} = []
    go (Case ann' es cs) =
      es
      ++ concatMap
          (\(CaseAlternative _ r) ->
            either
              (\es' -> map fst es' ++ map snd es')
              (\e' -> [e'])
              r
          )
          cs
      ++ [ Case ann' [e'] [c']
         | e' <- if length es > 1 then es else []
         , c' <- if length cs > 1 then cs else []
         ]
      ++ [ Case ann' es' cs'
         | es' <- shrinkList shrinkExpr es
         , cs' <- shrinkList shrinkCS cs
         ]
      where
      shrinkCS :: CaseAlternative Ann -> [CaseAlternative Ann]
      shrinkCS (CaseAlternative bs r) =
        [ CaseAlternative bs' r'
        | bs' <- shrinkList (\x -> [x]) bs
        , r'  <- rs
        ]
        where
        rs = case r of
          Right e -> Right <$> shrinkExpr e
          Left es' -> Left  <$> shrinkList (\(g, f) -> [(g', f') | g' <- shrinkExpr g, f' <- shrinkExpr f]) es'
    go (Let ann' bs e) =
      e : [ Let ann' bs' e' | bs' <- shrinkList shrinkBind bs, e' <- shrinkExpr e ]
    go _ = []

shrinkExpr :: Expr Ann -> [Expr Ann]
shrinkExpr = map unPSExpr . shrink . PSExpr

shrinkBind :: Bind Ann -> [Bind Ann]
shrinkBind (NonRec ann' n e) = NonRec ann' n <$> shrinkExpr e
shrinkBind (Rec as) = Rec <$> shrinkList (\(x, e) -> map (x,) $ shrinkExpr e) as

exprDepth :: Expr a -> Int
exprDepth (Literal _ (ArrayLiteral es)) = foldr (\e x -> exprDepth e `max` x) 1 es + 1
exprDepth (Literal _ (ObjectLiteral o)) = foldr (\(_, e) x -> exprDepth e `max` x) 1 o + 1
exprDepth (Literal{})   = 1
exprDepth Constructor{} = 1
exprDepth (Accessor _ _ e) = 1 + exprDepth e
exprDepth (ObjectUpdate _ e es) = 1 + exprDepth e + foldr (\(_, f) x -> exprDepth f `max` x) 1 es
exprDepth (Abs _ _ e) = 1 + exprDepth e
exprDepth (App _ e f) = 1 + exprDepth e `max` exprDepth f
exprDepth Var{}       = 1
exprDepth (Case _ es cs) = 1 + foldr (\f x -> exprDepth f `max` x) cdepth es
  where
  cdepth = foldr (\(CaseAlternative _ r) x -> either (foldr (\(g, e) y -> exprDepth g `max` exprDepth e `max` y) 1) exprDepth r `max` x) 1 cs
exprDepth (Let _ _ e) = 1 + exprDepth e

prop_exprDistribution :: PSExpr Ann -> Property
prop_exprDistribution (PSExpr e) =
    collect (exprDepth' e)
  $ tabulate "classify expressions" (cls e) True
  where
  cls :: Expr a -> [String]
  cls Literal{}      = ["Literal"]
  cls Constructor{}  = ["Constructor"]
  cls Accessor{}     = ["Accessor"]
  cls ObjectUpdate{} = ["ObjectUpdate"]
  cls Abs{}          = ["Abs"]
  cls App{}          = ["App"]
  cls Var{}          = ["Var"]
  cls (Case _ _ cs)  = "Case" : foldl' (\x c -> clsCaseAlternative c ++ x) [] cs
    where
    clsCaseAlternative (CaseAlternative {caseAlternativeResult}) =
      either (foldl' (\x (g, f) -> cls g ++ cls f ++ x) []) cls caseAlternativeResult
  cls Let{}          = ["Let"]

  exprDepth' expr = case exprDepth expr of
    n | n < 10     -> n
      | n < 100   -> 10 * (n `div` 10)
      | n < 1000  -> 25 * (n `div` 25)
      | otherwise -> 100 * (n `div` 100)
