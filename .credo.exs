import Config

config :credo,
  configs: [
    %{
      name: "default",
      strict: true,
      files: %{
        included: ["lib/", "test/", "examples/", "docs/", "agents/", "mix.exs"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      checks: [
        {Credo.Check.Consistency.LineEndings, []},
        {Credo.Check.Consistency.ParameterPatternMatching, []},
        {Credo.Check.Consistency.SpaceAroundOperators, []},
        {Credo.Check.Consistency.TabsOrSpaces, []},
        {Credo.Check.Design.AliasUsage, [priority: :low, if_nested_deeper_than: 2, if_called_more_often_than: 2]},
        {Credo.Check.Design.TagTODO, [exit_status: 2]},
        {Credo.Check.Readability.AliasOrder, []},
        {Credo.Check.Readability.FunctionNames, []},
        {Credo.Check.Readability.LargeNumbers, []},
        {Credo.Check.Readability.MaxLineLength, [priority: :low, max_length: 100]},
        {Credo.Check.Readability.ModuleAttributeNames, []},
        {Credo.Check.Readability.ModuleDoc, [except: [:ex_unit_case]]},
        {Credo.Check.Readability.MultiAlias, false},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs, []},
        {Credo.Check.Readability.RedundantBlankLines, []},
        {Credo.Check.Readability.StringSigils, []},
        {Credo.Check.Readability.VariableNames, []},
        {Credo.Check.Refactor.CondStatements, []},
        {Credo.Check.Refactor.CyclomaticComplexity, []},
        {Credo.Check.Refactor.FunctionArity, []},
        {Credo.Check.Refactor.LongQuoteBlocks, []},
        {Credo.Check.Refactor.MapInto, []},
        {Credo.Check.Refactor.MatchInCondition, []},
        {Credo.Check.Refactor.Nesting, []},
        {Credo.Check.Refactor.WithClauses, []},
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute, []},
        {Credo.Check.Warning.BoolOperationOnSameValues, []},
        {Credo.Check.Warning.ExpensiveEmptyEnumCheck, []},
        {Credo.Check.Warning.IExPry, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.MixEnv, []},
        {Credo.Check.Warning.OperationOnSameValues, []},
        {Credo.Check.Warning.UnsafeExec, []},
        {Credo.Check.Warning.UnusedEnumOperation, []},
        {Credo.Check.Warning.UnusedFileOperation, []},
        {Credo.Check.Warning.UnusedKeywordOperation, []},
        {Credo.Check.Warning.UnusedListOperation, []},
        {Credo.Check.Warning.UnusedPathOperation, []},
        {Credo.Check.Warning.UnusedRegexOperation, []},
        {Credo.Check.Warning.UnusedStringOperation, []},
        {Credo.Check.Warning.UnusedTupleOperation, []}
      ]
    }
  ]
