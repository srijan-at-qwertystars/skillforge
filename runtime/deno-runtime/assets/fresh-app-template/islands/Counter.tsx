import { useSignal } from "@preact/signals";

interface CounterProps {
  start: number;
}

export default function Counter({ start }: CounterProps) {
  const count = useSignal(start);

  return (
    <div
      style={{
        display: "flex",
        alignItems: "center",
        gap: "1rem",
        padding: "1rem",
        border: "1px solid #e5e7eb",
        borderRadius: "8px",
        marginTop: "1rem",
      }}
    >
      <button
        onClick={() => count.value--}
        style={{
          padding: "0.5rem 1rem",
          fontSize: "1.25rem",
          cursor: "pointer",
          borderRadius: "4px",
          border: "1px solid #d1d5db",
          background: "#f9fafb",
        }}
      >
        −
      </button>
      <span style={{ fontSize: "1.5rem", fontWeight: "bold", minWidth: "3rem", textAlign: "center" }}>
        {count}
      </span>
      <button
        onClick={() => count.value++}
        style={{
          padding: "0.5rem 1rem",
          fontSize: "1.25rem",
          cursor: "pointer",
          borderRadius: "4px",
          border: "1px solid #d1d5db",
          background: "#f9fafb",
        }}
      >
        +
      </button>
    </div>
  );
}
