using System;
using System.Collections.Generic;
using Microsoft.SqlServer.TransactSql.ScriptDom;

namespace SimpleSqlAssessment {
    public sealed class SqlHit {
        public string Kind { get; set; }
        public string Value { get; set; }
        public int Line { get; set; }
    }
    public sealed class SqlVisitor : TSqlFragmentVisitor {
        public readonly List<SqlHit> Hits = new List<SqlHit>();
        private void Add(string kind, string value, TSqlFragment node) {
            Hits.Add(new SqlHit { Kind=kind, Value=value, Line=node.StartLine });
        }
        public override void ExplicitVisit(ExecuteStatement node) {
            var entity = node.ExecuteSpecification.ExecutableEntity;
            var procedure = entity as ExecutableProcedureReference;
            if (procedure != null) {
                var reference = procedure.ProcedureReference == null ? null : procedure.ProcedureReference.ProcedureReference;
                if (reference != null && reference.Name != null)
                    Add("Procedure", reference.Name.BaseIdentifier.Value, node);
                else Add("DynamicGap", "Variable procedure name", node);
            }
            var dynamicSql = entity as ExecutableStringList;
            if (dynamicSql != null) {
                if (dynamicSql.Strings.Count == 1 && dynamicSql.Strings[0] is StringLiteral)
                    Add("DynamicConstant", ((StringLiteral)dynamicSql.Strings[0]).Value, node);
                else Add("DynamicGap", "Runtime-built executable string", node);
            }
            base.ExplicitVisit(node);
        }
        public override void ExplicitVisit(SchemaObjectName node) {
            if (node.ServerIdentifier != null) Add("LinkedServer", node.ServerIdentifier.Value, node);
            if (node.DatabaseIdentifier != null
                && !(node.DatabaseIdentifier.Value.Equals("tempdb", StringComparison.OrdinalIgnoreCase) && node.BaseIdentifier.Value.StartsWith("#")))
                Add("CrossDatabase", node.DatabaseIdentifier.Value, node);
            if (node.SchemaIdentifier != null && node.SchemaIdentifier.Value.Equals("sys", StringComparison.OrdinalIgnoreCase)
                && node.BaseIdentifier.Value.Equals("database_principal_aliases", StringComparison.OrdinalIgnoreCase))
                Add("DatabasePrincipalAlias", "sys.database_principal_aliases", node);
            base.ExplicitVisit(node);
        }
        public override void ExplicitVisit(MultiPartIdentifierCallTarget node) {
            var identifiers = node.MultiPartIdentifier.Identifiers;
            if (identifiers.Count >= 2) Add("CrossDatabase", identifiers[identifiers.Count - 2].Value, node);
            if (identifiers.Count >= 3) Add("LinkedServer", identifiers[identifiers.Count - 3].Value, node);
            base.ExplicitVisit(node);
        }
        public override void ExplicitVisit(OpenRowsetTableReference node) {
            Add("ProviderRowset", node.ProviderName == null ? "" : node.ProviderName.Value, node);
            base.ExplicitVisit(node);
        }
        public override void ExplicitVisit(BulkInsertStatement node) {
            Add("BulkInsert", node.From == null ? "" : node.From.Value, node);
            base.ExplicitVisit(node);
        }
        public override void ExplicitVisit(BulkOpenRowset node) {
            Add("BulkRowset", node.DataFiles.Count == 1 ? node.DataFiles[0].Value : "", node);
            base.ExplicitVisit(node);
        }
    }
}
