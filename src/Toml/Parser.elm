module Toml.Parser exposing (parse)

import Char
import Dict exposing (Dict)
import Parser
    exposing
        ( (|.)
        , (|=)
        , Count(..)
        , Parser
        , andThen
        , delayedCommit
        , end
        , fail
        , ignore
        , inContext
        , keep
        , keyword
        , lazy
        , map
        , oneOf
        , oneOrMore
        , succeed
        , symbol
        , zeroOrMore
        )
import Toml


parse : String -> Result Parser.Error Toml.Document
parse input =
    input
        |> Parser.run (document emptyAcc)
        |> Result.map .final


type alias Key =
    ( String, List String )


type alias Acc =
    { final : Toml.Document
    , current : Toml.Document
    , context : List String
    , isArray : Bool
    }


emptyAcc : Acc
emptyAcc =
    { final = Dict.empty
    , current = Dict.empty
    , context = []
    , isArray = False
    }


type Entry
    = Empty
    | KVPair ( Key, Toml.Value )
    | Header Bool Key


document : Acc -> Parser Acc
document acc =
    succeed identity
        |. ws
        |= parseEntry
        |> andThen (commit acc)
        |> andThen
            (\newAcc ->
                oneOf
                    [ end |> andThen (\_ -> finalize newAcc)
                    , lazy (\_ -> document newAcc)
                    ]
            )


parseEntry : Parser Entry
parseEntry =
    oneOf
        [ map (\_ -> Empty) comment
        , map (\_ -> Empty) eol
        , map KVPair kvPair
        ]


commit : Acc -> Entry -> Parser Acc
commit acc entry =
    case entry of
        Empty ->
            succeed acc

        KVPair ( key, val ) ->
            case addKVPair key val acc.current of
                Ok newDoc ->
                    succeed { acc | current = newDoc }

                Err e ->
                    fail e

        Header isArray k ->
            -- TODO: finalize previous stuff
            succeed acc


addKVPair : Key -> Toml.Value -> Toml.Document -> Result String Toml.Document
addKVPair ( key, rest ) val doc =
    case rest of
        [] ->
            if existingKey key doc then
                Err <| "Duplicate key: `" ++ key ++ "`"
            else
                Ok <| Dict.insert key val doc

        x :: xs ->
            find key doc
                |> Result.andThen (addKVPair ( x, xs ) val)
                |> Result.map (saveAsKey key doc)


saveAsKey : String -> Toml.Document -> Toml.Document -> Toml.Document
saveAsKey key docToSaveIn docToSave =
    Dict.insert key (Toml.Table docToSave) docToSaveIn


find : String -> Toml.Document -> Result String Toml.Document
find key doc =
    case Dict.get key doc of
        Just (Toml.Table t) ->
            Ok t

        Just _ ->
            Err <| "Key is not a table: `" ++ key ++ "`"

        Nothing ->
            Ok Dict.empty


existingKey : String -> Toml.Document -> Bool
existingKey key doc =
    Dict.member key doc


finalize : Acc -> Parser Acc
finalize acc =
    case acc.context of
        [] ->
            succeed
                { acc
                    | final = Dict.union acc.final acc.current
                    , current = Dict.empty
                    , context = []
                    , isArray = False
                }

        k :: rest ->
            if acc.isArray then
                fail "no support for array tables yet"
            else
                case addKVPair ( k, rest ) (Toml.Table acc.current) acc.final of
                    Ok v ->
                        succeed
                            { acc
                                | final = v
                                , current = Dict.empty
                                , context = []
                                , isArray = False
                            }

                    Err e ->
                        fail e


ws : Parser ()
ws =
    ignore zeroOrMore (chars [ ' ', '\t' ])


chars : List Char -> Char -> Bool
chars xs x =
    List.member x xs


noneMatch : List (Char -> Bool) -> Char -> Bool
noneMatch matchers c =
    not <| List.any (\m -> m c) matchers


comment : Parser String
comment =
    inContext "comment" <|
        succeed identity
            |. symbol "#"
            |= keep zeroOrMore ((/=) '\n')
            |. eol


eol : Parser ()
eol =
    oneOf [ ignore oneOrMore ((==) '\n'), end ]


eolOrComment : Parser ()
eolOrComment =
    oneOf
        [ eol
        , map (\_ -> ()) comment
        ]


kvPair : Parser ( Key, Toml.Value )
kvPair =
    inContext "key value pair" <|
        succeed (,)
            |= key
            |. symbol "="
            |. ws
            |= value
            |. eolOrComment


key : Parser Key
key =
    let
        rest : String -> List String -> Parser ( String, List String )
        rest k xs =
            oneOf
                [ succeed identity
                    |. ws
                    |= keyPart
                    |> delayedCommit (symbol ".")
                    |> andThen (\x -> rest k (x :: xs))
                , succeed ( k, List.reverse xs )
                ]
    in
    keyPart |> andThen (\k -> rest k [])


keyPart : Parser String
keyPart =
    oneOf
        [ bareKey
        , literalString
        , regularString
        ]
        |. ws


bareKey : Parser String
bareKey =
    succeed identity
        |= keep oneOrMore isKeyChar


isKeyChar : Char -> Bool
isKeyChar c =
    Char.isUpper c || Char.isLower c || Char.isDigit c || List.member c [ '_', '-' ]


value : Parser Toml.Value
value =
    oneOf
        [ map Toml.String string
        , map Toml.Bool bool
        , map Toml.Int int
        , map Toml.Float float
        , map Toml.Array array
        , map Toml.Table table
        ]
        |. ws


int : Parser Int
int =
    Parser.fail "TODO: Support ints"


float : Parser Float
float =
    Parser.fail "TODO: Support floats"


array : Parser Toml.ArrayValue
array =
    Parser.fail "TODO"


table : Parser Toml.Document
table =
    Parser.fail "TODO"


string : Parser String
string =
    oneOf [ literalString, regularString ]


literalString : Parser String
literalString =
    succeed identity
        |. symbol "'"
        |= keep zeroOrMore (\c -> c /= '\'' && c /= '\n')
        |. symbol "'"


regularString : Parser String
regularString =
    succeed identity
        |. symbol "\""
        |= regularStringContent ""
        |. symbol "\""


regularStringContent : String -> Parser String
regularStringContent acc =
    let
        {- This little trick allows us to piece the parts together. -}
        continue : String -> Parser String
        continue string =
            regularStringContent <| acc ++ string
    in
    oneOf
        [ {- First things first, escaped control characters.
             This means that characters like `\n` must be escaped as `\\n`
             So a literal backslash followed by a literal `n`.
          -}
          escapedControlCharacter |> andThen continue

        {- Arbitrary unicode can be embedded using `\uXXXX` where the `X`s form
           a valid hexadecimal sequence.
        -}
        , escapedUnicode |> andThen continue

        {- Finally, we have the rest of unicode, specifically disallowing certain
           things: control characters, literal `\` and literal `"`.
        -}
        , nonControlCharacters |> andThen continue

        {- If none of the above produce anything, we succeed with what we've
           accumulated so far.
        -}
        , succeed acc
        ]


escapedControlCharacter : Parser String
escapedControlCharacter =
    -- TODO: check TOML spec if this is correct
    [ ( "\\\"", "\"" )
    , ( "\\\\", "\\" )
    , ( "\\b", "\x08" )
    , ( "\\f", "\x0C" )
    , ( "\\n", "\n" )
    , ( "\\r", "\x0D" )
    , ( "\\t", "\t" )
    ]
        |> List.map symbolicString
        |> oneOf


symbolicString : ( String, String ) -> Parser String
symbolicString ( expected, replacement ) =
    succeed replacement |. symbol expected


escapedUnicode : Parser String
escapedUnicode =
    {- TOML (and soon, Elm) allow arbitrary UTF-16 codepoints to be written
       using `\uBEEF` syntax. These may also appear in escaped version in TOML,
       so a literal `\u` followed by 4 hexadecimal characters.

       This means something like a space may also be written as `\\u0020`

       TODO: TOML doesn't actually allow UTF-16 codepoints, but rather unicode
       scalar values
    -}
    succeed (Char.fromCode >> String.fromChar)
        |. symbol "\\u"
        |= hexQuad


hexQuad : Parser Int
hexQuad =
    keep (Exactly 4) Char.isHexDigit |> andThen hexQuadToInt


hexQuadToInt : String -> Parser Int
hexQuadToInt quad =
    ("0x" ++ quad)
        -- Kind of cheating here.
        |> String.toInt
        |> result fail succeed


nonControlCharacters : Parser String
nonControlCharacters =
    {- So basically, anything other than control characters, literal backslashes
       (which are already handled, unless it's invalid toml), and the closing `"`
    -}
    keep oneOrMore
        (noneMatch [ (==) '"', (==) '\\', Char.toCode >> isControlChar ])


isControlChar : Char.KeyCode -> Bool
isControlChar keyCode =
    (keyCode < 0x20) || (keyCode == 0x7F)


bool : Parser Bool
bool =
    oneOf
        [ map (always True) (keyword "true")
        , map (always False) (keyword "false")
        ]


result : (e -> v) -> (a -> v) -> Result e a -> v
result onErr onOk res =
    case res of
        Ok v ->
            onOk v

        Err e ->
            onErr e