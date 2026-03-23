#!/usr/bin/env tsx
// effect-layer-viz.ts — Visualize Effect Layer dependency graph
//
// Usage:
//   npx tsx effect-layer-viz.ts <src-directory>
//   npx tsx effect-layer-viz.ts ./src
//   npx tsx effect-layer-viz.ts ./src --format=mermaid
//   npx tsx effect-layer-viz.ts ./src --format=dot
//
// Scans TypeScript files for Context.Tag definitions, Layer.effect/Layer.succeed
// declarations, and yield* ServiceTag usage to build a dependency graph.
//
// Output formats:
//   --format=text     (default) ASCII tree
//   --format=mermaid  Mermaid diagram (paste into GitHub markdown)
//   --format=dot      Graphviz DOT format

import * as fs from "node:fs"
import * as path from "node:path"

interface ServiceNode {
  name: string
  file: string
  dependencies: string[]
  hasLayer: boolean
}

const servicePattern = /class\s+(\w+)\s+extends\s+Context\.Tag\s*\(/g
const layerEffectPattern =
  /(?:const|let|export\s+const)\s+(\w+)\s*=\s*Layer\.(?:effect|scoped)\s*\(\s*(\w+)/g
const layerSucceedPattern =
  /(?:const|let|export\s+const)\s+(\w+)\s*=\s*Layer\.succeed\s*\(\s*(\w+)/g
const layerMergePattern =
  /Layer\.merge\s*\(([^)]+)\)/g
const yieldServicePattern = /yield\*\s+(\w+)/g

function findTsFiles(dir: string): string[] {
  const results: string[] = []
  const entries = fs.readdirSync(dir, { withFileTypes: true })
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name)
    if (entry.isDirectory() && entry.name !== "node_modules" && entry.name !== "dist") {
      results.push(...findTsFiles(fullPath))
    } else if (entry.isFile() && /\.tsx?$/.test(entry.name) && !entry.name.endsWith(".d.ts")) {
      results.push(fullPath)
    }
  }
  return results
}

function analyzeFile(filePath: string, services: Map<string, ServiceNode>): void {
  const content = fs.readFileSync(filePath, "utf-8")
  const relPath = path.relative(process.cwd(), filePath)

  // Find Context.Tag definitions
  let match: RegExpExecArray | null
  const localServices = new Set<string>()

  const svcRegex = new RegExp(servicePattern.source, "g")
  while ((match = svcRegex.exec(content)) !== null) {
    const name = match[1]
    localServices.add(name)
    if (!services.has(name)) {
      services.set(name, { name, file: relPath, dependencies: [], hasLayer: false })
    }
  }

  // Find Layer definitions and their dependencies
  const layerRegex = new RegExp(layerEffectPattern.source, "g")
  while ((match = layerRegex.exec(content)) !== null) {
    const [, _layerName, serviceName] = match
    const node = services.get(serviceName)
    if (node) {
      node.hasLayer = true
      // Find yield* references within the Layer body (rough heuristic: scan ahead)
      const bodyStart = match.index + match[0].length
      const bodyEnd = Math.min(bodyStart + 2000, content.length)
      const body = content.slice(bodyStart, bodyEnd)

      const yieldRegex = new RegExp(yieldServicePattern.source, "g")
      let yieldMatch: RegExpExecArray | null
      while ((yieldMatch = yieldRegex.exec(body)) !== null) {
        const dep = yieldMatch[1]
        if (services.has(dep) && dep !== serviceName) {
          node.dependencies.push(dep)
        }
      }
    }
  }

  const succeedRegex = new RegExp(layerSucceedPattern.source, "g")
  while ((match = succeedRegex.exec(content)) !== null) {
    const [, _layerName, serviceName] = match
    const node = services.get(serviceName)
    if (node) node.hasLayer = true
  }
}

function renderText(services: Map<string, ServiceNode>): string {
  const lines: string[] = ["", "Effect Layer Dependency Graph", "=" .repeat(40), ""]

  for (const [name, node] of services) {
    const status = node.hasLayer ? "✅" : "❌"
    lines.push(`${status} ${name} (${node.file})`)
    if (node.dependencies.length > 0) {
      for (const dep of node.dependencies) {
        lines.push(`   └── depends on: ${dep}`)
      }
    }
  }

  const noLayer = [...services.values()].filter((n) => !n.hasLayer)
  if (noLayer.length > 0) {
    lines.push("", "⚠️  Services without Layer implementations:")
    for (const n of noLayer) {
      lines.push(`   - ${n.name} (${n.file})`)
    }
  }

  return lines.join("\n")
}

function renderMermaid(services: Map<string, ServiceNode>): string {
  const lines: string[] = ["```mermaid", "graph TD"]

  for (const [name, node] of services) {
    const style = node.hasLayer ? `${name}[${name}]` : `${name}[/${name}/]`
    lines.push(`  ${style}`)
    for (const dep of node.dependencies) {
      lines.push(`  ${name} --> ${dep}`)
    }
  }

  lines.push("```")
  return lines.join("\n")
}

function renderDot(services: Map<string, ServiceNode>): string {
  const lines: string[] = ["digraph layers {", '  rankdir=BT;', '  node [shape=box];']

  for (const [name, node] of services) {
    const attrs = node.hasLayer ? 'style=filled, fillcolor="#c8e6c9"' : 'style=filled, fillcolor="#ffcdd2"'
    lines.push(`  "${name}" [${attrs}];`)
    for (const dep of node.dependencies) {
      lines.push(`  "${name}" -> "${dep}";`)
    }
  }

  lines.push("}")
  return lines.join("\n")
}

// Main
const args = process.argv.slice(2)
const srcDir = args.find((a) => !a.startsWith("--")) || "./src"
const formatArg = args.find((a) => a.startsWith("--format="))
const format = formatArg?.split("=")[1] || "text"

if (!fs.existsSync(srcDir)) {
  console.error(`Directory not found: ${srcDir}`)
  process.exit(1)
}

const services = new Map<string, ServiceNode>()
const files = findTsFiles(srcDir)

// First pass: find all services
for (const file of files) {
  const content = fs.readFileSync(file, "utf-8")
  const svcRegex = new RegExp(servicePattern.source, "g")
  let match: RegExpExecArray | null
  while ((match = svcRegex.exec(content)) !== null) {
    services.set(match[1], {
      name: match[1],
      file: path.relative(process.cwd(), file),
      dependencies: [],
      hasLayer: false,
    })
  }
}

// Second pass: find layers and dependencies
for (const file of files) {
  analyzeFile(file, services)
}

switch (format) {
  case "mermaid":
    console.log(renderMermaid(services))
    break
  case "dot":
    console.log(renderDot(services))
    break
  default:
    console.log(renderText(services))
}
