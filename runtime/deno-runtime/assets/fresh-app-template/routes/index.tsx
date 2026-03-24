import Counter from "../islands/Counter.tsx";

export default function HomePage() {
  return (
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1.0" />
        <title>Fresh App</title>
        <style>{`
          body {
            font-family: system-ui, -apple-system, sans-serif;
            max-width: 640px;
            margin: 2rem auto;
            padding: 0 1rem;
            color: #1a1a1a;
          }
          h1 { color: #2563eb; }
          p { line-height: 1.6; }
          .features {
            display: grid;
            gap: 1rem;
            margin-top: 2rem;
          }
          .feature {
            padding: 1rem;
            border: 1px solid #e5e7eb;
            border-radius: 8px;
          }
          .feature h3 { margin-top: 0; }
        `}</style>
      </head>
      <body>
        <h1>🍋 Fresh App</h1>
        <p>
          Welcome to your Fresh app! This page is server-rendered.
          The counter below is an interactive island — it's the only
          JavaScript sent to the client.
        </p>

        {/* This island is hydrated on the client */}
        <Counter start={0} />

        <div class="features">
          <div class="feature">
            <h3>🏝️ Islands Architecture</h3>
            <p>Only interactive components ship JavaScript to the client.</p>
          </div>
          <div class="feature">
            <h3>⚡ Server Rendered</h3>
            <p>Pages are rendered on the server for fast initial load.</p>
          </div>
          <div class="feature">
            <h3>🦕 Deno Native</h3>
            <p>Built on Deno with zero configuration TypeScript.</p>
          </div>
        </div>
      </body>
    </html>
  );
}
