using System;
using System.Collections.Generic;
using System.Drawing;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

public static class Switcher
{
    const string ProviderId     = "deepseek";
    const string DefaultBaseUrl = "https://api.deepseek.com/";
    const string OfficialModel  = "gpt-6-astra";
    const string OfficialEffort = "low";
    const string OfficialSvc    = "default";
    const string DefaultDsModel = "deepseek-v4-flash-vision-exp";

    static readonly Dictionary<string, string> DsModelNames = new Dictionary<string, string>
    {
        { "deepseek-v4-flash",             "DeepSeek-V4-Flash" },
        { "deepseek-v4-pro",               "DeepSeek-V4-Pro" },
        { "deepseek-v4-flash-vision-exp",  "DeepSeek-V4-Flash-Vision" }
    };

    static readonly string[] DsSetKeys = new string[]
    {
        "model", "model_provider", "preferred_auth_method", "forced_login_method",
        "model_reasoning_effort", "model_catalog_json"
    };

    static readonly string[] DelOnDs = new string[]
    {
        "profile", "oss_provider", "openai_base_url", "model_context_window",
        "model_auto_compact_token_limit", "model_auto_compact_token_limit_scope",
        "base_instructions", "model_instructions_file", "compact_prompt",
        "experimental_compact_prompt_file", "service_tier", "model_verbosity",
        "model_reasoning_summary", "plan_mode_reasoning_effort",
        "experimental_use_unified_exec_tool"
    };

    public static string GetCodexHome()
    {
        string c = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (!string.IsNullOrEmpty(c)) return c;
        return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex");
    }

    public static string ConfigPath(string home)  { return Path.Combine(home, "config.toml"); }
    public static string ModelsPath(string home)  { return Path.Combine(home, "models.json"); }
    public static string SwitchDir(string home)   { return Path.Combine(home, "codex-switch"); }
    public static string SwitchModels(string home){ return Path.Combine(SwitchDir(home), "models.json"); }
    public static string SwitchKey(string home)   { return Path.Combine(SwitchDir(home), "api-key.txt"); }
    public static string SwitchState(string home) { return Path.Combine(SwitchDir(home), "state.txt"); }

    public static string CatalogValue(string home)
    {
        return ModelsPath(home).Replace('\\', '/');
    }

    // ------------------------------------------------------------- TOML scanner
    class TomlScan
    {
        public int Depth;
        public string MlState = "";
        public void Update(string line)
        {
            int n = line.Length;
            int i = 0;
            string instr = "";
            while (i < n)
            {
                char c = line[i];
                string c3 = (i + 3 <= n) ? line.Substring(i, 3) : "";
                if (MlState != "")
                {
                    if (MlState == "basic"   && c3 == "\"\"\"") { MlState = ""; i += 3; continue; }
                    if (MlState == "literal" && c3 == "'''")    { MlState = ""; i += 3; continue; }
                    if (MlState == "basic"   && c == '\\')      { i += 2; continue; }
                    i++; continue;
                }
                if (instr != "")
                {
                    if (instr == "basic") { if (c == '\\') { i += 2; continue; } if (c == '"') instr = ""; }
                    else                  { if (c == '\'') instr = ""; }
                    i++; continue;
                }
                if (c3 == "\"\"\"") { MlState = "basic";   i += 3; continue; }
                if (c3 == "'''")    { MlState = "literal"; i += 3; continue; }
                switch (c)
                {
                    case '#': return;
                    case '"': instr = "basic"; break;
                    case '\'': instr = "literal"; break;
                    case '[': Depth++; break;
                    case ']': if (Depth > 0) Depth--; break;
                }
                i++;
            }
        }
    }

    static string GetTomlKey(string line)
    {
        string l = line.Trim();
        if (l.Length == 0 || l.StartsWith("#")) return "";
        int eq = l.IndexOf('=');
        if (eq < 1) return "";
        return l.Substring(0, eq).Trim().Trim('"').Trim('\'');
    }

    static string GetTomlValue(string line)
    {
        string l = line.Trim();
        int eq = l.IndexOf('=');
        if (eq < 0) return "";
        return l.Substring(eq + 1).Trim();
    }

    static string GetSectionName(string line)
    {
        string h = line.Trim();
        int close = h.IndexOf(']');
        if (close > 0) h = h.Substring(0, close + 1);
        h = h.TrimStart('[').TrimEnd(']').Trim();
        h = h.Replace("\"", "").Replace("'", "");
        return h;
    }

    static string[] ReadLines(string path)
    {
        if (!File.Exists(path)) throw new FileNotFoundException("config.toml not found: " + path);
        string raw = File.ReadAllText(path);
        raw = raw.Replace("\r\n", "\n");
        raw = raw.TrimEnd('\n');
        if (raw.Length == 0) return new string[0];
        return raw.Split('\n');
    }

    static void WriteConfig(string path, List<string> lines)
    {
        string content = string.Join("\n", lines.ToArray()) + "\n";

        // duplicate top-level key guard
        var dup = new Dictionary<string, bool>();
        var toml = new TomlScan();
        bool inLead = true;
        foreach (string l in lines)
        {
            string t = l.Trim();
            if (toml.MlState == "" && toml.Depth == 0 && t.StartsWith("[")) inLead = false;
            if (inLead)
            {
                string k = GetTomlKey(l);
                if (k != "")
                {
                    if (dup.ContainsKey(k)) throw new InvalidOperationException("duplicate top-level key: " + k);
                    dup[k] = true;
                }
            }
            toml.Update(l);
        }

        string tmp = path + ".switch-tmp";
        File.WriteAllText(tmp, content, new UTF8Encoding(false));
        File.Delete(path);
        File.Move(tmp, path);
    }

    // ------------------------------------------------------------- config transform
    static bool IsDsSet(string k)
    {
        foreach (string a in DsSetKeys) if (k == a) return true;
        return false;
    }

    static bool IsDelOnDs(string k)
    {
        foreach (string a in DelOnDs) if (k == a) return true;
        return false;
    }

    static string DsValue(string key, string slug, string catalog)
    {
        switch (key)
        {
            case "model":                  return "\"" + slug + "\"";
            case "model_provider":         return "\"" + ProviderId + "\"";
            case "preferred_auth_method":  return "\"apikey\"";
            case "forced_login_method":    return "\"api\"";
            case "model_reasoning_effort": return "\"high\"";
            case "model_catalog_json":     return "\"" + catalog + "\"";
            default:                       return "\"\"";
        }
    }

    static string OfficialValue(string key)
    {
        switch (key)
        {
            case "model":                  return "\"" + OfficialModel + "\"";
            case "model_reasoning_effort": return "\"" + OfficialEffort + "\"";
            case "service_tier":           return "\"" + OfficialSvc + "\"";
            default:                       return "\"\"";
        }
    }

    static bool ShouldSkipSection(string hdr)
    {
        return hdr == "model_providers." + ProviderId
            || hdr.StartsWith("model_providers." + ProviderId + ".")
            || hdr == "profiles"
            || hdr.StartsWith("profiles.");
    }

    static void ConsumeBlock(string[] lines, ref int idx, TomlScan toml)
    {
        while (idx < lines.Length)
        {
            toml.Update(lines[idx]);
            idx++;
            if (toml.MlState == "" && toml.Depth == 0) break;
        }
    }

    // mode=true -> DeepSeek ; mode=false -> official
    public static string TransformConfig(string configText, bool toDs, string slug, string catalog)
    {
        string[] lines = configText.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        // handle empty
        if (lines.Length == 1 && lines[0].Length == 0) lines = new string[0];

        var Out    = new List<string>();
        var seen   = new Dictionary<string, bool>();
        var toml   = new TomlScan();
        int idx = 0;
        string curSection = "";
        bool skipSection = false;
        int insAt = 0;

        while (idx < lines.Length)
        {
            string line = lines[idx];
            string trimmed = line.Trim();
            bool isHeader = toml.MlState == "" && toml.Depth == 0 && trimmed.StartsWith("[");

            if (isHeader)
            {
                string hdr = GetSectionName(line);
                curSection = hdr;
                skipSection = ShouldSkipSection(hdr);
                toml.Update(line);
                idx++;
                if (!skipSection) Out.Add(line);
                continue;
            }

            if (curSection != "")
            {
                if (skipSection) { toml.Update(line); idx++; continue; }
                Out.Add(line);
                toml.Update(line);
                idx++;
                continue;
            }

            string k = GetTomlKey(line);
            if (k != "")
            {
                if (toDs && IsDsSet(k))
                {
                    ConsumeBlock(lines, ref idx, toml);
                    Out.Add(k + " = " + DsValue(k, slug, catalog));
                    insAt = Out.Count;
                    seen[k] = true;
                    continue;
                }
                if (toDs && IsDelOnDs(k))
                {
                    ConsumeBlock(lines, ref idx, toml);
                    continue;
                }
                if (!toDs && (k == "model" || k == "model_reasoning_effort" || k == "service_tier"))
                {
                    ConsumeBlock(lines, ref idx, toml);
                    Out.Add(k + " = " + OfficialValue(k));
                    insAt = Out.Count;
                    seen[k] = true;
                    continue;
                }
                if (!toDs && IsOfficialRemove(k))
                {
                    ConsumeBlock(lines, ref idx, toml);
                    continue;
                }
            }

            Out.Add(line);
            if (k != "") insAt = Out.Count;
            toml.Update(line);
            idx++;
        }

        string[] setKeys = toDs ? DsSetKeys : new string[] { "model", "model_reasoning_effort", "service_tier" };
        var missing = new List<string>();
        foreach (string key in setKeys) if (!seen.ContainsKey(key)) missing.Add(key);

        var final = new List<string>();
        for (int i = 0; i < Out.Count; i++)
        {
            if (i == insAt && missing.Count > 0)
            {
                foreach (string key in missing)
                {
                    final.Add(key + " = " + (toDs ? DsValue(key, slug, catalog) : OfficialValue(key)));
                }
                missing.Clear();
                if (Out[i].Trim().StartsWith("[")) final.Add("");
            }
            final.Add(Out[i]);
        }
        foreach (string key in missing)
        {
            final.Add(key + " = " + (toDs ? DsValue(key, slug, catalog) : OfficialValue(key)));
        }

        if (toDs)
        {
            final.Add("");
            final.Add("[model_providers." + ProviderId + "]");
            final.Add("name = \"" + ProviderId + "\"");
            final.Add("base_url = \"" + DefaultBaseUrl + "\"");
            final.Add("wire_api = \"responses\"");
            final.Add("experimental_bearer_token = \"" + ApiKey + "\"");
        }

        return string.Join("\n", final.ToArray()) + "\n";
    }

    // Simplified official-remove set (service_tier is SET for official, so excluded).
    static bool IsOfficialRemove(string k)
    {
        if (k == "model_provider" || k == "preferred_auth_method" || k == "forced_login_method" || k == "model_catalog_json")
            return true;
        foreach (string a in DelOnDs) if (k == a && k != "service_tier") return true;
        return false;
    }

    // ------------------------------------------------------------- api key
    public static string ApiKey = "";

    static string GetProviderKey(string configText)
    {
        string[] lines = configText.Replace("\r\n", "\n").TrimEnd('\n').Split('\n');
        var toml = new TomlScan();
        bool inSection = false;
        string found = "";
        foreach (string l in lines)
        {
            string t = l.Trim();
            bool isHeader = toml.MlState == "" && toml.Depth == 0 && t.StartsWith("[");
            if (isHeader) inSection = GetSectionName(l) == "model_providers." + ProviderId;
            if (inSection && GetTomlKey(l) == "experimental_bearer_token")
                found = GetTomlValue(l).Trim('"').Trim('\'');
            toml.Update(l);
        }
        return found;
    }

    public static string ResolveApiKey(string codexHome, string currentConfigText)
    {
        string fromConfig = GetProviderKey(currentConfigText);
        if (fromConfig != "") return fromConfig;
        string keyFile = SwitchKey(codexHome);
        if (File.Exists(keyFile))
        {
            string s = File.ReadAllText(keyFile).Trim();
            if (s != "") return s;
        }
        string env = Environment.GetEnvironmentVariable("DEEPSEEK_API_KEY");
        if (!string.IsNullOrEmpty(env)) return env.Trim();
        return null; // caller prompts
    }

    public static void SaveApiKey(string codexHome, string key)
    {
        if (string.IsNullOrEmpty(key)) return;
        Directory.CreateDirectory(SwitchDir(codexHome));
        File.WriteAllText(SwitchKey(codexHome), key, new UTF8Encoding(false));
    }

    // ------------------------------------------------------------- models.json
    static string ExtractEmbeddedCatalog()
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        string resName = null;
        foreach (string n in asm.GetManifestResourceNames())
            if (n == "deepseek-models.json" || n.EndsWith(".deepseek-models.json")) { resName = n; break; }
        if (resName == null) return null;
        using (Stream s = asm.GetManifestResourceStream(resName))
        {
            if (s == null) return null;
            string tmp = Path.Combine(Path.GetTempPath(), "codex-switch-models.json");
            using (FileStream fs = File.Create(tmp))
            {
                s.CopyTo(fs);
            }
            return tmp;
        }
    }

    public static void EnsureModelsJson(string codexHome)
    {
        string modelsPath = ModelsPath(codexHome);
        string swModels = SwitchModels(codexHome);
        Directory.CreateDirectory(SwitchDir(codexHome));
        if (File.Exists(modelsPath)) { File.Copy(modelsPath, swModels, true); return; }
        string src = null;
        if (File.Exists(swModels)) src = swModels;
        else src = ExtractEmbeddedCatalog();
        if (src == null) return; // caller warns
        File.Copy(src, modelsPath, true);
        if (src != swModels) File.Copy(src, swModels, true);
    }

    public static void ArchiveModels(string codexHome)
    {
        string modelsPath = ModelsPath(codexHome);
        string swModels = SwitchModels(codexHome);
        Directory.CreateDirectory(SwitchDir(codexHome));
        if (!File.Exists(modelsPath)) return;
        File.Copy(modelsPath, swModels, true);
        File.Delete(modelsPath);
    }

    // ------------------------------------------------------------- backup
    public static void BackupConfig(string codexHome)
    {
        Directory.CreateDirectory(SwitchDir(codexHome));
        string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
        string target = Path.Combine(SwitchDir(codexHome), "config.toml.prev-" + stamp);
        File.Copy(ConfigPath(codexHome), target, true);
    }

    // ------------------------------------------------------------- switch operations
    public static void DoSwitch(string codexHome, bool toDs, string modelSlug, string apiKey)
    {
        if (!File.Exists(ConfigPath(codexHome)))
            throw new FileNotFoundException("config.toml not found: " + ConfigPath(codexHome));

        string cfgPath = ConfigPath(codexHome);
        string current = File.ReadAllText(cfgPath);
        string catalog = CatalogValue(codexHome);

        BackupConfig(codexHome);

        if (toDs)
        {
            string key = apiKey;
            if (string.IsNullOrEmpty(key)) key = ResolveApiKey(codexHome, current);
            if (string.IsNullOrEmpty(key))
            {
                // prompt (only when there is an interactive session) -> GUI provides via apiKey
                throw new InvalidOperationException("DeepSeek API key was not found. Set DEEPSEEK_API_KEY or provide it in the UI.");
            }
            ApiKey = key; // used by TransformConfig provider block
            SaveApiKey(codexHome, key);
            string transformed = TransformConfig(current, true, modelSlug, catalog);
            WriteConfig(cfgPath, new List<string>(transformed.Replace("\r\n", "\n").TrimEnd('\n').Split('\n')));
            EnsureModelsJson(codexHome);
            WriteState(codexHome, "deepseek", modelSlug);
        }
        else
        {
            bool dsPresent = current.Contains("model_providers." + ProviderId);
            string saved = GetProviderKey(current);
            if (saved != "") SaveApiKey(codexHome, saved);
            string transformed = TransformConfig(current, false, null, catalog);
            WriteConfig(cfgPath, new List<string>(transformed.Replace("\r\n", "\n").TrimEnd('\n').Split('\n')));
            ArchiveModels(codexHome);
            WriteState(codexHome, "official", OfficialModel);
        }
    }

    static void WriteState(string codexHome, string state, string model)
    {
        string content = "state=" + state + "\n"
                       + "model_slug=" + model + "\n"
                       + "official_model=" + OfficialModel + "\n"
                       + "switched_at=" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + "\n";
        File.WriteAllText(SwitchState(codexHome), content, new UTF8Encoding(false));
    }

    // ------------------------------------------------------------- status
    public static string Status(string codexHome)
    {
        string cfgPath = ConfigPath(codexHome);
        if (!File.Exists(cfgPath)) return "config.toml not found: " + cfgPath;
        string c = File.ReadAllText(cfgPath);
        bool isDs = c.Contains("model_providers." + ProviderId) ||
                    (c.IndexOf("model", StringComparison.Ordinal) >= 0 && c.Contains("\"deepseek-"));
        string model = "";
        foreach (string l in c.Replace("\r\n", "\n").Split('\n'))
        {
            if (model == "" && GetTomlKey(l) == "model") model = GetTomlValue(l);
        }
        bool models = File.Exists(ModelsPath(codexHome));
        bool archived = File.Exists(SwitchModels(codexHome));
        bool key = File.Exists(SwitchKey(codexHome));
        return (isDs ? "DeepSeek" : "official (OpenAI)")
             + "  |  " + model
             + "  |  models.json: " + models
             + "  |  archived: " + archived
             + "  |  key: " + key;
    }

    // ------------------------------------------------------------- selftest (no GUI)
    public static int SelfTest(string codexHome, string reportPath)
    {
        var sb = new StringBuilder();
        string cfg = ConfigPath(codexHome);
        sb.AppendLine("home=" + codexHome);
        try
        {
            Environment.SetEnvironmentVariable("DEEPSEEK_API_KEY", "sk-DUMMY000000000000000000000000000000000000000");
            DoSwitch(codexHome, false, "", null);
            string c1 = File.ReadAllText(cfg);
            sb.AppendLine("after_off model=" + FirstValue(c1, "model") + " hasDeepseek=" + c1.Contains("[model_providers.deepseek]"));

            DoSwitch(codexHome, true, "deepseek-v4-pro", null);
            string c2 = File.ReadAllText(cfg);
            sb.AppendLine("after_dspro model=" + FirstValue(c2, "model") + " hasDeepseek=" + c2.Contains("[model_providers.deepseek]"));

            DoSwitch(codexHome, true, "deepseek-v4-flash-vision-exp", null);
            string c3 = File.ReadAllText(cfg);
            sb.AppendLine("after_dsvis model=" + FirstValue(c3, "model") + " hasDeepseek=" + c3.Contains("[model_providers.deepseek]"));
            sb.AppendLine("modelsPresent=" + File.Exists(ModelsPath(codexHome)));
            sb.AppendLine("archivedPresent=" + File.Exists(SwitchModels(codexHome)));
            sb.AppendLine("result=OK");
        }
        catch (Exception e)
        {
            sb.AppendLine("result=ERROR");
            sb.AppendLine(e.GetType().Name + ": " + e.Message);
        }
        File.WriteAllText(reportPath, sb.ToString(), new UTF8Encoding(false));
        return 0;
    }

    static string FirstValue(string text, string key)
    {
        foreach (string l in text.Replace("\r\n", "\n").Split('\n'))
            if (GetTomlKey(l) == key) return GetTomlValue(l).Trim('"').Trim('\'');
        return "";
    }
}

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (args.Length >= 3 && args[0] == "--selftest")
        {
            return Switcher.SelfTest(args[1], args[2]);
        }
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
        return 0;
    }
}
