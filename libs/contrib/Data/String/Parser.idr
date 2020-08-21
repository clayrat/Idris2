||| A simple parser combinator library for strings. Inspired by attoparsec zepto.
module Data.String.Parser
import Control.Monad.Identity
import Control.Monad.Trans

import Data.Strings
import Data.Fin
import Data.List

%default total

||| The input state, pos is position in the string and maxPos is the length of the input string.
public export
record State where
    constructor S
    input : String
    pos : Int
    maxPos : Int

Show State where
    show s = "(" ++ show s.input ++ ", " ++ show s.pos ++ ", " ++ show s.maxPos ++ ")"

||| Result of applying a parser
public export
data Result a = Fail Int String | OK a State

public export
record ParseT (m : Type -> Type) (a : Type) where
    constructor P
    runParser : State -> m (Result a)

public export
Parser : Type -> Type
Parser = ParseT Identity

public export
implementation Monad m => Functor (ParseT m) where
    map f p = P $ \state =>
         do res <- p.runParser state
            case res of
                OK r state' => pure (OK (f r) state')
                Fail i err => pure (Fail i err)

public export
Monad m => Applicative (ParseT m) where
    pure x = P $ \s => pure (OK x s)
    f <*> x = P $ \s => case !(f.runParser s) of
                            OK f' s' => case !(x.runParser s') of
                                            OK r rs => pure (OK (f' r) rs)
                                            Fail i err => pure (Fail i err)
                            Fail i err => pure (Fail i err)

public export
Monad m => Monad (ParseT m) where
    m >>= k = P $ \state =>
        do res <- m.runParser state
           case res of
                OK a state' => (k a).runParser state'
                Fail i err => pure (Fail i err)

public export
Monad m => Alternative (ParseT m) where
    empty = P $ \s => pure $ Fail (s.pos) "no alternative left"
    a <|> b = P $ \s => case !(a.runParser s) of
                            OK r s' => pure $ OK r s'
                            Fail _ _ => b.runParser s

public export
MonadTrans ParseT where
    lift x = P $ \s => do res <- x
                          pure $ OK res s

||| Run a parser in a monad
||| Returns a tuple of the result and final position on success.
||| Returns an error message on failure.
export
parseT : Monad m => ParseT m a -> String -> m (Either String (a, Int))
parseT p str = do res <- p.runParser (S str 0 (strLength str))
                  case res of
                      OK r s => pure $ Right (r, s.pos)
                      Fail i err => pure $ Left $ fastAppend ["Parse failed at position ", show i, ": ", err]

||| Run a parser in a pure function
||| Returns a tuple of the result and final position on success.
||| Returns an error message on failure.
export
parse : Parser a -> String -> Either String (a, Int)
parse p str = runIdentity $ parseT p str

||| Combinator that replaces the error message on failure.
||| This allows combinators to output relevant errors
export
(<?>) : Monad m => ParseT m a -> String -> ParseT m a
(<?>) p msg = P $ \s => case !(p.runParser s) of
                            OK r s' => pure $ OK r s'
                            Fail i _ => pure $ Fail i msg

infixl 0 <?>

||| Fail with some error message
export
fail : Monad m => String -> ParseT m a
fail x = P $ \s => pure $ Fail s.pos x

||| Returns the result of the parser `p` or `def` if it fails.
export
option : Monad m => a -> ParseT m a -> ParseT m a
option def p = p <|> pure def

||| Returns a Maybe that contains the result of `p` if it succeeds or `Nothing` if it fails.
export
optional : Monad m => ParseT m a -> ParseT m (Maybe a)
optional p = (Just <$> p) <|> pure Nothing

||| Discards the result of a parser
export
skip : Monad m => ParseT m a -> ParseT m ()
skip = ignore

mutual
    ||| Succeeds if `p` succeeds, will continue to match `p` until it fails
    ||| and accumulate the results in a list
    export
    covering
    some : Monad m => ParseT m a -> ParseT m (List a)
    some p = pure (!p :: !(many p))

    ||| Always succeeds, will accumulate the results of `p` in a list until it fails.
    export
    covering
    many : Monad m => ParseT m a -> ParseT m (List a)
    many p = some p <|> pure []

||| Parse left-nested lists of the form `((init op arg) op arg) op arg`
export
covering
hchainl : Monad m => ParseT m init -> ParseT m (init -> arg -> init) -> ParseT m arg -> ParseT m init
hchainl pini pop parg = pini >>= go
  where
  covering
  go : init -> ParseT m init
  go x = (do op <- pop
             arg <- parg
             go $ op x arg) <|> pure x

||| Parse right-nested lists of the form `arg op (arg op (arg op end))`
export
covering
hchainr : Monad m => ParseT m arg -> ParseT m (arg -> end -> end) -> ParseT m end -> ParseT m end
hchainr parg pop pend = go id <*> pend
  where
  covering
  go : (end -> end) -> ParseT m (end -> end)
  go f = (do arg <- parg
             op <- pop
             go $ f . op arg) <|> pure f

||| Succeeds if the next char satisfies the predicate `f`
export
satisfy : Monad m => (Char -> Bool) -> ParseT m Char
satisfy f = P $ \s => pure $ if s.pos < s.maxPos
                                  then let ch = assert_total $ strIndex s.input s.pos in
                                       if f ch
                                           then OK ch (S s.input (s.pos + 1) s.maxPos)
                                           else Fail (s.pos) "satisfy"
                                  else Fail (s.pos) "satisfy"

||| Always succeeds, applies the predicate `f` on chars until it fails and creates a string
||| from the results.
export
covering
takeWhile : Monad m => (Char -> Bool) -> ParseT m String
takeWhile f = pack <$> many (satisfy f)

||| Succeeds if the string `str` follows.
export
string : Monad m => String -> ParseT m ()
string str = P $ \s => pure $ let len = strLength str in
                              if s.pos+len <= s.maxPos
                                  then let head = strSubstr s.pos len s.input in
                                       if head == str
                                         then OK () (S s.input (s.pos + len) s.maxPos)
                                         else Fail (s.pos) ("string " ++ show str)
                                  else Fail (s.pos) ("string " ++ show str)

||| Succeeds if the next char is `c`
export
char : Monad m => Char -> ParseT m ()
char c = ignore $ satisfy (== c)

||| Parses a space character
export
space : Monad m => ParseT m Char
space = satisfy isSpace

||| Parses one or more space characters
export
covering
spaces : Monad m => ParseT m ()
spaces = skip (many space) <?> "white space"

||| Discards brackets around a matching parser
export
parens : Monad m => ParseT m a -> ParseT m a
parens p = char '(' *> p <* char ')'

||| Discards whitespace after a matching parser
export
covering
lexeme : Monad m => ParseT m a -> ParseT m a
lexeme p = p <* spaces

||| Matches a specific string, then skips following whitespace
export
covering
token : Monad m => String -> ParseT m ()
token s = lexeme (skip (string s)) <?> "token " ++ show s

||| Matches a single digit
export
digit : Monad m => ParseT m (Fin 10)
digit = do x <- satisfy isDigit
           case lookup x digits of
                Nothing => P $ \s => pure $ Fail s.pos "not a digit"
                Just y => P $ \s => pure $ OK y s
  where
    digits : List (Char, Fin 10)
    digits = [ ('0', 0)
             , ('1', 1)
             , ('2', 2)
             , ('3', 3)
             , ('4', 4)
             , ('5', 5)
             , ('6', 6)
             , ('7', 7)
             , ('8', 8)
             , ('9', 9)
             ]

fromDigits : Num a => ((Fin 10) -> a) -> List (Fin 10) -> a
fromDigits f xs = foldl (addDigit) 0 xs
where
  addDigit : a -> (Fin 10) -> a
  addDigit num d = 10*num + (f d)

intFromDigits : List (Fin 10) -> Integer
intFromDigits = fromDigits finToInteger

natFromDigits : List (Fin 10) -> Nat
natFromDigits = fromDigits finToNat

||| Matches a natural number
export
covering
natural : Monad m => ParseT m Nat
natural = natFromDigits <$> some digit

||| Matches an integer, eg. "12", "-4"
export
covering
integer : Monad m => ParseT m Integer
integer = do minus <- optional (char '-')
             x <- some digit
             pure $ case minus of
                      Nothing => intFromDigits x
                      Just y => (intFromDigits x)*(-1)
