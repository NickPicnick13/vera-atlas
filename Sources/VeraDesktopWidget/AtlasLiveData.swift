import CryptoKit
import Foundation

/// Local, read-only graph and trace inputs. Only opaque graph IDs and closed categories leave Swift.
struct AtlasMemoryAccessEvent {
    let id: String
    let operation: String
    let skillID: String?
    let documentID: String?
    let toolID: String?
    let outcome: String?
    let projectID: String?
    let origin: String?
    let actorID: String?
    let modelID: String?
    let role: String?
    let stage: String?
    let processID: String?
    let taskID: String?
}

struct AtlasLiveData {
    private let traceURL: URL
    private let accessURL: URL
    private let nodes: [[String: Any]]
    private let edges: [[String: Any]]
    private let knownNodes: Set<String>
    private let knownEdges: Set<String>

    init(arguments: [String] = CommandLine.arguments) {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        if let i = arguments.firstIndex(of: "--trace-file"), arguments.indices.contains(i + 1) {
            traceURL = URL(fileURLWithPath: arguments[i + 1])
        } else {
            traceURL = home.appendingPathComponent("Library/Application Support/VeraAtlas/trace.jsonl")
        }
        let catalogAccessURL: URL
        if let i = arguments.firstIndex(of: "--access-file"), arguments.indices.contains(i + 1) {
            catalogAccessURL = URL(fileURLWithPath: arguments[i + 1])
        } else if let custom = ProcessInfo.processInfo.environment["VERA_ATLAS_ACCESS_PATH"],
                  !custom.isEmpty {
            catalogAccessURL = URL(fileURLWithPath: custom)
        } else {
            catalogAccessURL = home.appendingPathComponent("Library/Application Support/VeraAtlas/atlas-access.jsonl")
        }
        accessURL = catalogAccessURL
        // The application reads a prepared, sanitized static graph from its own resources.
        // Only the standalone build/export utility needs to inspect the Obsidian directory.
        if let seed = Bundle.main.resourceURL?.appendingPathComponent("atlas-base.json"),
           let base = Self.readObject(seed),
           let nodes = base["nodes"] as? [[String: Any]], let edges = base["edges"] as? [[String: Any]] {
            let g = Self.addPersisted(Self.addDocs(nodes, edges), at: catalogAccessURL)
            self.nodes = g.0
            self.edges = g.1
            self.knownNodes = Set(g.0.compactMap { $0["id"] as? String })
            self.knownEdges = Set(g.1.map { Self.edgeKey($0["a"], $0["b"]) })
            return
        }
        // Community edition: when no bundle seed is available, load the
        // deterministic public demo. Never inspect the user's Obsidian vault.
        let fallback = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("examples/demo-graph.json")
        let demo = Self.readObject(fallback) ?? [:]
        let g = Self.addPersisted(Self.addDocs(
            demo["nodes"] as? [[String: Any]] ?? [],
            demo["edges"] as? [[String: Any]] ?? []
        ), at: catalogAccessURL)
        self.nodes = g.0
        self.edges = g.1
        self.knownNodes = Set(g.0.compactMap { $0["id"] as? String })
        self.knownEdges = Set(g.1.map { Self.edgeKey($0["a"], $0["b"]) })
    }

    /// Restore learned opaque document nodes from the existing access JSONL
    /// catalog. Unlike time-limited pulses, node topology survives window
    /// restarts and log rotation. No file paths or document contents are read.
    private static func addPersisted(
        _ graph: ([[String:Any]], [[String:Any]]), at url: URL
    ) -> ([[String:Any]], [[String:Any]]) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return graph }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 8_000_000),
              let newline = bytes.firstIndex(of: 10),
              let payload = (try? JSONSerialization.jsonObject(
                with: Data(bytes.prefix(upTo: newline)))) as? [String:Any],
              payload["type"] as? String == "atlas_catalog" else { return graph }
        var ns = graph.0, es = graph.1
        var nodeIDs = Set(ns.compactMap { $0["id"] as? String })
        var edgeIDs = Set(es.map { edgeKey($0["a"], $0["b"]) })
        func appendNode(_ id: String) {
            if nodeIDs.insert(id).inserted {
                ns.append(["id":id,"g":"src","w":0.8])
            }
        }
        func appendEdge(_ a: String, _ b: String) {
            if edgeIDs.insert(edgeKey(a,b)).inserted {
                es.append(["a":a,"b":b,"w":0.75])
            }
        }
        let docs = payload["document_ids"] as? [String] ?? []
        for doc in docs {
            guard doc.range(of: #"^f-[0-9a-f]{24}$"#,
                            options: .regularExpression) != nil else { continue }
            appendNode(doc)
            appendEdge("d-harness-documents", doc)
        }
        for tool in payload["chatgpt_tool_ids"] as? [String] ?? [] {
            guard tool.range(of: #"^t-[0-9a-f]{24}$"#,
                             options: .regularExpression) != nil else { continue }
            appendNode(tool)
            appendEdge("d-chatgpt-tools",tool)
        }
        // Actual ChatGPT workbench actions are distinct short-lived process
        // dots. Catalog retains only the most recent 96 verified spans.
        for pair in payload["chatgpt_processes"] as? [[String]] ?? [] where pair.count == 2 {
            let process=pair[0],tool=pair[1]
            guard process.range(of: #"^r-[0-9a-f]{24}$"#,options:.regularExpression) != nil,
                  tool.range(of: #"^t-[0-9a-f]{24}$"#,options:.regularExpression) != nil else {continue}
            appendNode(tool)
            appendNode(process)
            appendEdge("d-chatgpt-tools",tool)
            appendEdge(tool,process)
        }
        // Restored IDs are opaque, but only actual observed sessions/models.
        for pair in payload["harness_actors"] as? [[String]] ?? [] where pair.count == 2 {
            let actor=pair[0],role=pair[1]
            guard actor.range(of: #"^h-[0-9a-f]{24}$"#, options: .regularExpression) != nil,
                  role == "main" || role == "worker" else { continue }
            appendNode(actor)
            appendEdge("d-harness-active",actor)
            if role == "worker" { appendEdge("d-team-activity",actor) }
        }
        for model in payload["harness_models"] as? [String] ?? [] {
            guard model.range(of: #"^m-[0-9a-f]{24}$"#, options: .regularExpression) != nil else { continue }
            appendNode(model)
            appendEdge("d-harness-models",model)
        }
        for pair in payload["harness_actor_models"] as? [[String]] ?? [] where pair.count == 2 {
            let actor=pair[0],model=pair[1]
            guard actor.range(of: #"^h-[0-9a-f]{24}$"#, options: .regularExpression) != nil,
                  model.range(of: #"^m-[0-9a-f]{24}$"#, options: .regularExpression) != nil
            else { continue }
            appendNode(actor)
            appendNode(model)
            appendEdge("d-harness-active",actor)
            appendEdge("d-harness-models",model)
            appendEdge(actor,model)
        }
        // Real external model dots and genuine observed request/task paths.
        for model in payload["process_models"] as? [String] ?? [] {
            guard model.range(of: #"^m-[0-9a-f]{24}$"#, options:.regularExpression) != nil else {continue}
            appendNode(model)
            appendEdge("d-external-processes",model)
        }
        for task in payload["process_tasks"] as? [String] ?? [] {
            guard task.range(of: #"^q-[0-9a-f]{24}$"#, options:.regularExpression) != nil else {continue}
            appendNode(task)
            appendEdge("d-process-tasks",task)
        }
        for triple in payload["process_instances"] as? [[String]] ?? [] where triple.count==3 {
            let process=triple[0],model=triple[1],task=triple[2]
            guard process.range(of: #"^r-[0-9a-f]{24}$"#,options:.regularExpression) != nil,
                  model.range(of: #"^m-[0-9a-f]{24}$"#,options:.regularExpression) != nil,
                  task.range(of: #"^q-[0-9a-f]{24}$"#,options:.regularExpression) != nil else {continue}
            appendNode(process)
            appendNode(model)
            appendNode(task)
            appendEdge("d-external-processes",model)
            appendEdge("d-process-tasks",task)
            appendEdge(model,process)
            appendEdge(process,task)
        }
        let links = payload["project_links"] as? [[String]] ?? []
        for link in links where link.count == 2 {
            let project = link[0], doc = link[1]
            guard project.range(of: #"^p-[0-9a-f]{24}$"#,
                                options: .regularExpression) != nil,
                  doc.range(of: #"^f-[0-9a-f]{24}$"#,
                            options: .regularExpression) != nil else { continue }
            appendNode(project)
            appendNode(doc)
            appendEdge("d-projects",project)
            appendEdge("d-harness-documents",doc)
            appendEdge(project,doc)
        }
        return (ns,es)
    }

    // Verified reader -> document routes, not simulated semantic connections.
    private static let routes: [[String]] = [
        ["d-vera-core","d-reader"],["d-reader","d-canon"],
        ["d-reader","d-protocol"],["d-reader","d-index"],
        ["d-reader","d-flash"],["d-reader","d-soroka"],
        ["d-reader","d-mempalace"],["d-reader","d-knowledge-graph"],
        ["d-canon","d-node-memory"],["d-canon","d-node-journal"],
        ["d-canon","d-node-routes"],["d-canon","d-node-models"],
        ["d-canon","d-node-dsh"],["d-canon","d-node-learning"]
    ]
    private static func addDocs(_ nodes: [[String:Any]], _ edges: [[String:Any]])
        -> ([[String:Any]], [[String:Any]]) {
        var ns=nodes, es=edges
        var ids=Set(ns.compactMap { $0["id"] as? String })
        var keys=Set(es.map { edgeKey($0["a"],$0["b"]) })
        for pair in routes {
            for id in pair where ids.insert(id).inserted {
                ns.append(["id":id,"g":"src","w":0.95])
            }
            if keys.insert(edgeKey(pair[0],pair[1])).inserted {
                es.append(["a":pair[0],"b":pair[1],"w":0.85])
            }
        }
        // DSH skill catalog is discovered at launch, not copied into another index.
        // The ID is a hash of the skill's directory name; no paths or skill texts
        // are sent to the web scene. Do not treat catalog presence as a usage event.
        // ChatGPT's VeraCore skill is a separate installed entry point,
        // not a DeepSeek Harness skill. Keep the provenance of both catalogs.
        let chatHub = "d-chatgpt-skills"
        if ids.insert(chatHub).inserted {
            ns.append(["id":chatHub,"g":"src","w":1.0])
        }
        if keys.insert(edgeKey(chatHub,"d-vera-core")).inserted {
            es.append(["a":chatHub,"b":"d-vera-core","w":0.9])
        }
        // Genuine ChatGPT connector results are distinct from native DSH tools.
        let chatToolHub = "d-chatgpt-tools"
        if ids.insert(chatToolHub).inserted {
            ns.append(["id":chatToolHub,"g":"src","w":0.9])
        }
        if keys.insert(edgeKey("d-reader",chatToolHub)).inserted {
            es.append(["a":"d-reader","b":chatToolHub,"w":0.75])
        }
        // Actual file read attempts are attached to this hub incrementally;
        // unknown file names/paths are never sent to the rendering surface.
        let toolHub = "d-harness-tools"
        if ids.insert(toolHub).inserted {
            ns.append(["id":toolHub,"g":"src","w":0.9])
        }
        if keys.insert(edgeKey("d-reader",toolHub)).inserted {
            es.append(["a":"d-reader","b":toolHub,"w":0.75])
        }
        let toolNames = [
            "bash","grep","glob","web_fetch","web_search","read_image",
            "send_message","schedule_list","schedule_view","schedule_edit",
            "schedule_create","team_task_get","team_task_update","team_task_create",
            "team_task_list","subagent","subagent_fork","wait_agent","list_agents",
            "plugin_manager","job_list","job_output","job_kill","workflow",
            "present","working_directory","load_workspace_dependencies",
            "todo_write","get_goal","update_goal","create_goal"
        ]
        for name in toolNames {
            let id = "t-" + opaque("dsh-tool:" + name)
            if ids.insert(id).inserted { ns.append(["id":id,"g":"src","w":0.8]) }
            if keys.insert(edgeKey(toolHub,id)).inserted {
                es.append(["a":toolHub,"b":id,"w":0.75])
            }
        }
        // Project hub connects only to verified local project roots at read time.
        let projectsHub = "d-projects"
        if ids.insert(projectsHub).inserted {
            ns.append(["id":projectsHub,"g":"src","w":1.0])
        }
        if keys.insert(edgeKey("d-reader",projectsHub)).inserted {
            es.append(["a":"d-reader","b":projectsHub,"w":0.75])
        }
        // Group real team-related tool activity without guessing agent status.
        let teamHub = "d-team-activity"
        if ids.insert(teamHub).inserted { ns.append(["id":teamHub,"g":"src","w":0.95]) }
        if keys.insert(edgeKey("d-harness-tools",teamHub)).inserted {
            es.append(["a":"d-harness-tools","b":teamHub,"w":0.8])
        }
        for name in ["team_task_get","team_task_update","team_task_create","team_task_list",
                     "subagent","subagent_fork","wait_agent","list_agents"] {
            let id = "t-" + opaque("dsh-tool:" + name)
            if keys.insert(edgeKey(teamHub,id)).inserted {
                es.append(["a":teamHub,"b":id,"w":0.8])
            }
        }
        let documentHub = "d-harness-documents"
        if ids.insert(documentHub).inserted {
            ns.append(["id":documentHub,"g":"src","w":0.9])
        }
        if keys.insert(edgeKey("d-reader",documentHub)).inserted {
            es.append(["a":"d-reader","b":documentHub,"w":0.75])
        }
        let hub = "d-harness-skills"
        if ids.insert(hub).inserted { ns.append(["id":hub,"g":"src","w":1.0]) }
        // Stable route to the catalog, not an assertion that VeraCore was invoked.
        if keys.insert(edgeKey("d-reader",hub)).inserted {
            es.append(["a":"d-reader","b":hub,"w":0.7])
        }
        let names = skillNames()
        for name in names {
            let skill = skillID(name)
            if ids.insert(skill).inserted {
                ns.append(["id":skill,"g":"src","w":0.8])
            }
            if keys.insert(edgeKey(hub,skill)).inserted {
                es.append(["a":hub,"b":skill,"w":0.75])
            }
        }
        // Two independently observable runtime entry points. These are
        // provenance hubs, not assertions that any tool was called.
        for id in ["d-chatgpt","d-deepseek-harness","d-harness-active","d-harness-models",
                   "d-external-processes","d-process-tasks"] {
            if ids.insert(id).inserted {
                ns.append(["id":id,"g":"src","w":1.0])
            }
        }
        let originRoutes = [
            ["d-reader","d-chatgpt"],
            ["d-chatgpt","d-chatgpt-skills"], ["d-chatgpt","d-chatgpt-tools"],
            ["d-reader","d-deepseek-harness"],
            ["d-deepseek-harness","d-harness-active"],
            ["d-deepseek-harness","d-harness-models"],
            ["d-reader","d-external-processes"],
            ["d-external-processes","d-process-tasks"],
            ["d-deepseek-harness","d-harness-tools"],
            ["d-deepseek-harness","d-harness-skills"],
            ["d-deepseek-harness","d-harness-documents"],
            ["d-deepseek-harness","d-team-activity"]
        ]
        for pair in originRoutes where keys.insert(edgeKey(pair[0],pair[1])).inserted {
            es.append(["a":pair[0],"b":pair[1],"w":0.8])
        }
        let indexed=sourceID("protocol_live")
        if ids.contains(indexed) && keys.insert(edgeKey("d-protocol",indexed)).inserted {
            es.append(["a":"d-protocol","b":indexed,"w":0.75])
        }
        return (ns,es)
    }
    private static func skillID(_ name: String) -> String {
        "k-" + opaque("dsh-skill:" + name)
    }
    private static func skillNames() -> [String] {
        // Optional DeepSeek Skills integration. No implicit access to ~/.dsh.
        guard let configured = ProcessInfo.processInfo.environment["VERA_ATLAS_DSH_SKILLS_DIR"],
              !configured.isEmpty else { return [] }
        let base = URL(fileURLWithPath: configured, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil)) ?? []
        var names = Set<String>()
        for path in entries {
            let name = path.lastPathComponent
            guard name.range(of: #"^[a-z0-9][a-z0-9_-]{0,79}$"#,
                             options: .regularExpression) != nil else { continue }
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("SKILL.md").path) {
                names.insert(name)
            }
        }
        // Already observed native skill tool calls for bundled skills not present
        // in .dsh/skills. This does not synthesize new invocation events.
        // User-provided on-disk skills only; no private seeded catalog.
        return names.sorted()
    }

    private static func routeEdges(_ op: String) -> [[String]] {
        // An adapter read is not proof of a ChatGPT VeraCore skill invocation.
        // The VeraCore node is part of the reference graph, never auto-pulsed.
        if op == "vera-core" {
            return [["d-chatgpt-skills","d-vera-core"],routes[0]]
        }
        if op == "shared-memory" { return Array(routes[1...3]) }
        let nodeNames=["node-memory":"d-node-memory","node-journal":"d-node-journal",
                       "node-routes":"d-node-routes","node-models":"d-node-models",
                       "node-dsh":"d-node-dsh","node-learning":"d-node-learning"]
        if let target=nodeNames[op] {
            return [["d-canon",target]]
        }
        let names=["canon":"d-canon","protocol":"d-protocol","index":"d-index",
                   "flash":"d-flash","soroka":"d-soroka","mempalace":"d-mempalace",
                   "knowledge-graph":"d-knowledge-graph"]
        guard let target=names[op] else { return [] }
        return [["d-reader",target]]
    }
    func primaryRouteDeltaJSON(_ op: String, skillID: String? = nil,
                               documentID: String? = nil, toolID: String? = nil,
                               outcome: String? = nil, projectID: String? = nil,
                               origin: String? = nil, actorID: String? = nil,
                               modelID: String? = nil, role: String? = nil,
                               stage: String? = nil, processID: String? = nil,
                               taskID: String? = nil) -> String? {
        if op == "process-event", let modelID, let processID, let taskID, let stage,
           ["result","started","retry"].contains(stage),
           modelID.range(of: #"^m-[0-9a-f]{24}$"#,options:.regularExpression) != nil,
           processID.range(of: #"^r-[0-9a-f]{24}$"#,options:.regularExpression) != nil,
           taskID.range(of: #"^q-[0-9a-f]{24}$"#,options:.regularExpression) != nil {
            // Live event: model is persistent; this attempt is a unique process.
            let route: [[String]] = [
                ["d-reader","d-deepseek-harness"],
                ["d-reader","d-external-processes"],
                ["d-external-processes",modelID],
                [modelID,processID],
                [processID,taskID],
                [taskID,"d-process-tasks"]
            ]
            let nodes: [[String:Any]] = [
                ["id":modelID,"g":"src","w":1.2],
                ["id":processID,"g":"src","w":0.94],
                ["id":taskID,"g":"src","w":0.86]
            ]
            let edges: [[String:Any]] = [
                ["a":"d-external-processes","b":modelID,"w":0.95],
                ["a":modelID,"b":processID,"w":0.9],
                ["a":processID,"b":taskID,"w":0.85],
                ["a":"d-process-tasks","b":taskID,"w":0.75]
            ]
            let failed = outcome == "provider_error" || outcome == "harness_timeout"
            let trace: [String:Any] = [
                "ts":ISO8601DateFormatter().string(from:Date()),
                "focusEdges":route,"selected":[],
                "eventFamily":"benchmark-process","eventStage":stage,
                "eventState":failed ? "error" : stage=="result" ? "returned" : "called"
            ]
            let payload: [String:Any] = ["nodes":nodes,"edges":edges,
                "trace":trace,"live":true,"memoryAccess":true]
            guard let bytes=try? JSONSerialization.data(withJSONObject:payload) else {return nil}
            return String(data:bytes,encoding:.utf8)
        }
        if op == "harness-event", let actorID, let role, let stage,
           actorID.range(of: #"^h-[0-9a-f]{24}$"#, options:.regularExpression) != nil,
           (role == "main" || role == "worker"), Self.harnessStages.contains(stage) {
            // Real source is a native Harness session event, never an invented
            // ChatGPT skill or a user-prompt interpretation.
            let team = role == "worker" || stage.hasPrefix("team-")
                || stage.hasPrefix("job-") || stage == "subagent-catalog"
            var links: [[String]] = [
                ["d-reader","d-deepseek-harness"],
                ["d-deepseek-harness","d-harness-active"],
                ["d-harness-active",actorID]
            ]
            var extraNodes: [[String:Any]] = [["id":actorID,"g":"src","w":0.88]]
            var extraEdges: [[String:Any]] = [
                ["a":"d-harness-active","b":actorID,"w":0.85]
            ]
            if team {
                links.append(contentsOf:[
                    ["d-deepseek-harness","d-team-activity"],
                    ["d-team-activity",actorID]
                ])
                extraEdges.append(["a":"d-team-activity","b":actorID,"w":0.8])
            }
            if let modelID, modelID.range(of: #"^m-[0-9a-f]{24}$"#,
                                           options:.regularExpression) != nil {
                extraNodes.append(["id":modelID,"g":"src","w":0.9])
                extraEdges.append(contentsOf:[
                    ["a":"d-harness-models","b":modelID,"w":0.85],
                    ["a":actorID,"b":modelID,"w":0.8]
                ])
                links.append(contentsOf:[
                    ["d-deepseek-harness","d-harness-models"],
                    ["d-harness-models",modelID],
                    [actorID,modelID]
                ])
            }
            // A model is a stable dot; actual work stages are separate
            // process dots. Distinct native events illuminate distinct paths.
            let digest=SHA256.hash(data:Data(("dsh-stage:"+actorID+":"+stage).utf8))
            let stageNode="v-"+digest.prefix(12).map {String(format:"%02x",$0)}.joined()
            extraNodes.append(["id":stageNode,"g":"src","w":0.75])
            extraEdges.append(["a":actorID,"b":stageNode,"w":0.86])
            links.append([actorID,stageNode])
            if let modelID, modelID.range(of: #"^m-[0-9a-f]{24}$"#,
                                           options:.regularExpression) != nil {
                extraEdges.append(["a":modelID,"b":stageNode,"w":0.88])
                links.append([modelID,stageNode])
            }
            if let toolID, toolID.range(of: #"^t-[0-9a-f]{24}$"#,
                                         options:.regularExpression) != nil {
                extraNodes.append(["id":toolID,"g":"src","w":0.8])
                extraEdges.append(contentsOf:[
                    ["a":stageNode,"b":toolID,"w":0.89],
                    ["a":"d-harness-tools","b":toolID,"w":0.8]
                ])
                links.append(contentsOf:[
                    [stageNode,toolID],["d-harness-tools",toolID]
                ])
            }
            let completed = ["turn-end","step-end","model-message","job-end","tool-result"]
                .contains(stage)
            let trace: [String:Any] = [
                "ts":ISO8601DateFormatter().string(from:Date()),
                "focusEdges":links, "selected":[],
                "eventFamily":team ? "harness-team" : "harness-model",
                "eventStage":stage,
                "eventState":completed ? "returned" : "called"
            ]
            let object: [String:Any] = ["nodes":extraNodes,"edges":extraEdges,
                "trace":trace,"live":true,"memoryAccess":true]
            guard let data=try? JSONSerialization.data(withJSONObject:object) else { return nil }
            return String(data:data,encoding:.utf8)
        }
        if op == "document", let documentID,
           documentID.range(of: #"^f-[0-9a-f]{24}$"#, options: .regularExpression) != nil {
            let edges: [[String]] = [["d-reader","d-harness-documents"],
                                     ["d-harness-documents",documentID]]
            let obj: [String:Any] = [
                "nodes": [["id":documentID,"g":"src","w":0.8]],
                "edges": [["a":"d-harness-documents","b":documentID,"w":0.8]],
                "trace": ["ts":ISO8601DateFormatter().string(from:Date()),
                          "focusEdges":edges,"selected":[]],
                "live":true,"memoryAccess":true
            ]
            guard let data = try? JSONSerialization.data(withJSONObject:obj) else { return nil }
            return String(data:data,encoding:.utf8)
        }
        if op == "project-link", let projectID, let documentID,
           projectID.range(of: #"^p-[0-9a-f]{24}$"#, options: .regularExpression) != nil,
           documentID.range(of: #"^f-[0-9a-f]{24}$"#, options: .regularExpression) != nil {
            let links: [[String]] = [["d-reader","d-projects"],["d-projects",projectID],
                                     [projectID,documentID]]
            let obj: [String:Any] = [
                "nodes":[["id":projectID,"g":"src","w":0.95],
                         ["id":documentID,"g":"src","w":0.8]],
                "edges":[["a":"d-projects","b":projectID,"w":0.8],
                         ["a":projectID,"b":documentID,"w":0.85]],
                "trace":["ts":ISO8601DateFormatter().string(from:Date()),
                         "focusEdges":links,"selected":[],
                         "eventState":"called","eventFamily":"project",
                         "projectID":projectID],
                "live":true,"memoryAccess":true
            ]
            guard let data=try? JSONSerialization.data(withJSONObject:obj) else{return nil}
            return String(data:data,encoding:.utf8)
        }
        if (op == "tool" || op == "tool-result"), let toolID,
           toolID.range(of: #"^t-[0-9a-f]{24}$"#, options: .regularExpression) != nil {
            let teamTools = ["team_task_get","team_task_update","team_task_create","team_task_list",
                             "subagent","subagent_fork","wait_agent","list_agents"]
            let isChatGPT = origin == "chatgpt"
            let isTeam = !isChatGPT && teamTools.contains {
                "t-" + Self.opaque("dsh-tool:" + $0) == toolID
            }
            var links: [[String]] = isChatGPT ?
                [["d-reader","d-chatgpt-tools"],["d-chatgpt-tools",toolID]] :
                isTeam ?
                [["d-reader","d-harness-tools"],["d-harness-tools","d-team-activity"],
                 ["d-team-activity",toolID]] :
                [["d-reader","d-harness-tools"],["d-harness-tools",toolID]]
            var extraNodes: [[String:Any]] = knownNodes.contains(toolID) ? [] :
                [["id":toolID,"g":"src","w":0.8]]
            var extraEdges: [[String:Any]] = knownNodes.contains(toolID) ? [] :
                [["a":isChatGPT ? "d-chatgpt-tools" : "d-harness-tools",
                  "b":toolID,"w":0.75]]
            if isChatGPT, let processID,
               processID.range(of: #"^r-[0-9a-f]{24}$"#,options:.regularExpression) != nil {
                links.append([toolID,processID])
                if !knownNodes.contains(processID) {
                    extraNodes.append(["id":processID,"g":"src","w":0.88])
                }
                extraEdges.append(["a":toolID,"b":processID,"w":0.86])
            }
            let object: [String:Any] = ["nodes":extraNodes,"edges":extraEdges,
                "trace":["ts":ISO8601DateFormatter().string(from:Date()),
                         "focusEdges":links,"selected":[],
                         "eventState":op == "tool-result" ? (outcome ?? "returned") : "called",
                         "eventFamily":isChatGPT ? "chatgpt-tool" : (isTeam ? "team" : "tool")],
                "live":true,"memoryAccess":true]
            guard let data = try? JSONSerialization.data(withJSONObject:object) else { return nil }
            return String(data:data,encoding:.utf8)
        }
        let links: [[String]]
        if op == "skill", let skillID, knownNodes.contains(skillID) {
            links = [["d-reader","d-harness-skills"],["d-harness-skills",skillID]]
        } else {
            links = Self.routeEdges(op)
        }
        guard !links.isEmpty else { return nil }
        let object: [String:Any]=["nodes":[],"edges":[],
            "trace":["ts":ISO8601DateFormatter().string(from:Date()),
                     "focusEdges":links,"selected":[]],
            "live":true,"memoryAccess":true]
        guard let data=try? JSONSerialization.data(withJSONObject:object) else { return nil }
        return String(data:data,encoding:.utf8)
    }

    private static func readObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func index(_ item: Any) -> Int? {
        if let n = item as? Int { return n }
        return (item as? String).flatMap { Int($0) }
    }

    private static let hexDigits = Array("0123456789abcdef".utf8)
    /// Fast lowercase hex: table lookup per byte instead of String(format:).
    private static func opaque(_ input: String) -> String {
        var out = [UInt8]()
        out.reserveCapacity(24)
        for byte in SHA256.hash(data: Data(input.utf8)).prefix(12) {
            out.append(Self.hexDigits[Int(byte >> 4)])
            out.append(Self.hexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: out, as: UTF8.self)
    }

    private static func sourceID(_ source: String) -> String { "s-" + opaque(source) }
    private static func chunkID(_ id: String, sourceID: String) -> String { "m-" + opaque(sourceID + ":" + id) }
    private static func edgeKey(_ a: Any?, _ b: Any?) -> String {
        let x = (a as? String) ?? "", y = (b as? String) ?? ""
        return x < y ? x + "\u{0}" + y : y + "\u{0}" + x
    }

    private static func idString(_ id: Any?) -> String? {
        let string = id as? String ?? (id as? NSNumber)?.stringValue
        return string?.isEmpty == false ? string : nil
    }

    private static func category(_ raw: String) -> String {
        let source = raw.lowercased()
        for marker in ["skysight", "session", "ideas", "lightrag", "graphify", "temporal", "telegram", "tg-private", "obsidian", "soroka", "palace", "note"] where source.contains(marker) {
            return marker
        }
        return "other"
    }

    /// Accept only an ordinary clock timestamp; do not pass arbitrary JSON strings to the scene.
    private static func sanitizedTrace(_ trace: [String: Any]) -> [String: Any] {
        let raw = trace["timestamp"] as? String ?? ""
        let timestamp = raw.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:?[0-9]{2})?$"#, options: .regularExpression) != nil ? raw : ""
        let candidates = trace["candidates"] as? [[String: Any]] ?? []
        var selected: [[String: String]] = [], focusEdges: [[String]] = [], emitted = Set<String>()
        for rawID in trace["selected"] as? [Any] ?? [] {
            guard let id = Self.idString(rawID), emitted.insert(id).inserted,
                  let candidate = candidates.first(where: { Self.idString($0["id"]) == id }),
                  let source = candidate["source"] as? String, !source.isEmpty else { continue }
            let a = sourceID(source), b = chunkID(id, sourceID: a)
            focusEdges.append([a, b])
            selected.append(["id": a, "chunk": b, "source": Self.category(source)])
        }
        return ["ts": timestamp, "selected": selected, "focusEdges": focusEdges]
    }

    /// Bounded tail read; a partially written last row is ignored rather than replacing the current scene.
    func lastTrace(matching accept: ([String: Any]) -> Bool = { _ in true }) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: traceURL) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        let start = end > 131_072 ? end - 131_072 : 0
        guard (try? handle.seek(toOffset: start)) != nil, let bytes = try? handle.readToEnd() else { return nil }
        for row in bytes.split(separator: 10).reversed() {
            if let t = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any],
               let ts = t["timestamp"] as? String, !ts.isEmpty, accept(t) { return t }
        }
        return nil
    }

    func lastReplayTrace() -> [String: Any]? {
        lastTrace { !(Self.sanitizedTrace($0)["focusEdges"] as? [[String]] ?? []).isEmpty }
    }

    func lastWorkTrace(for work: AtlasActivity.Work, observedAfter: Int64) -> [String: Any]? {
        guard work.promptAt > 0 else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return lastTrace { record in
            guard record["atlas_session"] as? String == work.sessionID,
                  let stamp = record["timestamp"] as? String, let date = iso.date(from: stamp) else { return false }
            let ms = Int64(date.timeIntervalSince1970 * 1000)
            // The hook emits its tagged trace immediately before the injected snapshot
            // is committed as a user message, so sessionListMetadata.lastPromptAt may
            // trail it by a few milliseconds. Keep the tolerance tight and do not cross
            // the last observed idle boundary.
            return ms >= max(work.promptAt - 100, observedAfter) && date.timeIntervalSinceNow <= 1 &&
                !(Self.sanitizedTrace(record)["focusEdges"] as? [[String]] ?? []).isEmpty
        }
    }

    /// Full snapshot at boot. Include confirmed live nodes not yet present in the static index.
    func payload(trace: [String: Any]?) -> String? {
        var payload: [String: Any] = ["nodes": nodes, "edges": edges]
        if let trace {
            let live = deltaObject(trace)
            payload["nodes"] = nodes + (live["nodes"] as? [[String: Any]] ?? [])
            payload["edges"] = edges + (live["edges"] as? [[String: Any]] ?? [])
            payload["trace"] = live["trace"]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func deltaObject(_ trace: [String: Any]) -> [String: Any] {
        var newNodes: [[String: Any]] = [], newEdges: [[String: Any]] = []
        var added = Set<String>(), seen = Set<String>()
        let candidates = trace["candidates"] as? [[String: Any]] ?? []
        for rawID in trace["selected"] as? [Any] ?? [] {
            guard let id = Self.idString(rawID),
                  let candidate = candidates.first(where: { Self.idString($0["id"]) == id }),
                  let source = candidate["source"] as? String, !source.isEmpty else { continue }
            let a = Self.sourceID(source), b = Self.chunkID(id, sourceID: a)
            if !knownNodes.contains(a), added.insert(a).inserted { newNodes.append(["id": a, "g": "src", "w": 1]) }
            if !knownNodes.contains(b), added.insert(b).inserted { newNodes.append(["id": b, "g": "chunk", "w": 1]) }
            let key = Self.edgeKey(a, b)
            if !knownEdges.contains(key), seen.insert(key).inserted {
                newEdges.append(["a": a, "b": b, "w": 1])
            }
        }
        return ["nodes": newNodes, "edges": newEdges, "trace": Self.sanitizedTrace(trace)]
    }

    private static let harnessStages: Set<String> = [
        "turn-start","turn-end","step-start","step-end","request",
        "model-attempt","model-message","model-retry","model-select",
        "job-start","job-end","team-task","team-message",
        "subagent-catalog","tool-call","tool-result"
    ]
    private static let accessOperations: Set<String> = [
        "flash", "shared-memory", "soroka", "mempalace", "knowledge-graph",
        "chatgpt-memory", "chatgpt-memory-write", "canon", "protocol", "index",
        "node-memory", "node-journal", "node-routes", "node-models",
        "node-dsh", "node-learning", "vera-core", "skill", "document", "tool",  "project-link", "tool-result", "harness-event", "process-event"
    ]

    private func readAccessEvents() -> [AtlasMemoryAccessEvent] {
        guard let handle = try? FileHandle(forReadingFrom: accessURL) else { return [] }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return [] }
        let start = end > 131_072 ? end - 131_072 : 0
        guard (try? handle.seek(toOffset: start)) != nil, var bytes = try? handle.readToEnd() else { return [] }
        if start > 0 {
            guard let newline = bytes.firstIndex(of: 10), newline + 1 < bytes.endIndex else { return [] }
            bytes = Data(bytes.suffix(from: newline + 1))
        }
        return bytes.split(separator: 10).compactMap { row in
            guard let object = (try? JSONSerialization.jsonObject(with: Data(row))) as? [String: Any],
                  object["type"] as? String == "memory_access",
                  let id = object["id"] as? String,
                  id.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil,
                  let operation = object["operation"] as? String,
                  Self.accessOperations.contains(operation) else { return nil }
            let skillID = object["skill_id"] as? String
            let documentID = object["document_id"] as? String
            let toolID = object["tool_id"] as? String
            let outcome = object["outcome"] as? String
            let projectID = object["project_id"] as? String
            let origin = object["origin"] as? String
            let actorID = object["actor_id"] as? String
            let modelID = object["model_id"] as? String
            let role = object["role"] as? String
            let stage = object["stage"] as? String
            let processID = object["process_id"] as? String
            let taskID = object["task_id"] as? String
            if origin != nil && origin != "chatgpt" { return nil }
            if origin == "chatgpt" && operation != "tool" && operation != "tool-result" { return nil }
            if operation == "harness-event" {
                guard let actorID,
                      actorID.range(of: #"^h-[0-9a-f]{24}$"#, options:.regularExpression) != nil,
                      role == "main" || role == "worker",
                      let stage, Self.harnessStages.contains(stage) else { return nil }
                if let modelID,
                   modelID.range(of: #"^m-[0-9a-f]{24}$"#, options:.regularExpression) == nil {
                    return nil
                }
            }
            if operation == "process-event" {
                // Old results create stable catalog nodes without fake live
                // flashes; only genuinely appended new results reach the UI.
                if stage == "snapshot" || stage == "configured" { return nil }
                guard let modelID, modelID.range(of: #"^m-[0-9a-f]{24}$"#,
                                                  options:.regularExpression) != nil,
                      let processID, processID.range(of: #"^r-[0-9a-f]{24}$"#,
                                                      options:.regularExpression) != nil,
                      let taskID, taskID.range(of: #"^q-[0-9a-f]{24}$"#,
                                                options:.regularExpression) != nil,
                      stage == "result" || stage == "started" || stage == "retry"
                else { return nil }
                if stage == "result" && outcome != "completed" &&
                   outcome != "provider_error" && outcome != "harness_timeout" { return nil }
            }
            if operation == "project-link" {
                guard let projectID, projectID.range(of: #"^p-[0-9a-f]{24}$"#,
                                                     options: .regularExpression) != nil,
                      let documentID, documentID.range(of: #"^f-[0-9a-f]{24}$"#,
                                                       options: .regularExpression) != nil
                else { return nil }
            }
            if operation == "tool-result" {
                guard outcome == "returned" || outcome == "error" else { return nil }
            }
            if operation == "tool" || operation == "tool-result" {
                if let processID {
                    guard origin == "chatgpt",
                          processID.range(of: #"^r-[0-9a-f]{24}$"#,
                                            options:.regularExpression) != nil else {return nil}
                }
                guard let toolID, toolID.range(of: #"^t-[0-9a-f]{24}$"#,
                                              options: .regularExpression) != nil else { return nil }
            }
            if operation == "document" {
                guard let documentID,
                      documentID.range(of: #"^f-[0-9a-f]{24}$"#,
                                       options: .regularExpression) != nil else { return nil }
            }
            if operation == "skill" {
                guard let skillID, skillID.range(of: #"^k-[0-9a-f]{24}$"#,
                                                 options: .regularExpression) != nil,
                      knownNodes.contains(skillID) else { return nil }
            }
            return AtlasMemoryAccessEvent(id: id, operation: operation, skillID: skillID,
                                          documentID: documentID, toolID: toolID,
                                          outcome: outcome, projectID: projectID,
                                          origin: origin, actorID: actorID,
                                          modelID: modelID, role: role, stage: stage,
                                          processID: processID, taskID: taskID)
        }
    }

    func latestAccessEventID() -> String? { readAccessEvents().last?.id }

    func accessEvents(after cursor: String?) -> [AtlasMemoryAccessEvent] {
        let events = readAccessEvents()
        guard let cursor else { return Array(events.suffix(8)) }
        if let index = events.lastIndex(where: { $0.id == cursor }) {
            return Array(events.dropFirst(index + 1).suffix(32))
        }
        return Array(events.suffix(8))
    }

    func trace(forAccessID accessID: String) -> [String: Any]? {
        guard accessID.range(of: #"^[0-9a-f]{32}$"#, options: .regularExpression) != nil else { return nil }
        return lastTrace { record in
            record["atlas_access_id"] as? String == accessID &&
                !(Self.sanitizedTrace(record)["focusEdges"] as? [[String]] ?? []).isEmpty
        }
    }

    var accessRevision: String? {
        guard let file = try? FileManager.default.attributesOfItem(atPath: accessURL.path),
              let stamp = file[.modificationDate] as? Date, let size = file[.size] as? NSNumber,
              let inode = file[.systemFileNumber] as? NSNumber else { return nil }
        return "\(stamp.timeIntervalSince1970):\(size):\(inode)"
    }

    var traceRevision: String? {
        guard let file = try? FileManager.default.attributesOfItem(atPath: traceURL.path),
              let stamp = file[.modificationDate] as? Date, let size = file[.size] as? NSNumber,
              let inode = file[.systemFileNumber] as? NSNumber else { return nil }
        return "\(stamp.timeIntervalSince1970):\(size):\(inode)"
    }

    func deltaJSON(trace: [String: Any], live: Bool = false, memoryAccess: Bool = false,
                   operation: String? = nil) -> String? {
        var object = deltaObject(trace)
        if operation == "flash", var t = object["trace"] as? [String:Any] {
            var links = t["focusEdges"] as? [[String]] ?? []
            links.append(contentsOf: Self.routeEdges("flash"))
            t["focusEdges"] = links
            object["trace"] = t
        }
        object["live"] = live
        if memoryAccess { object["memoryAccess"] = true }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
