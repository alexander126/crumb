export function Brand() {
  return (
    <span className="crumb-brand">
      <svg
        aria-hidden="true"
        viewBox="0 0 64 64"
        width="28"
        height="28"
        fill="currentColor"
      >
        {[13, 32, 51].flatMap((y) =>
          [13, 32, 51]
            .filter((x) => x !== 32 || y !== 32)
            .map((x) => <circle key={`${x}-${y}`} cx={x} cy={y} r="5" />),
        )}
        <circle
          cx="32"
          cy="32"
          r="9"
          fill="none"
          stroke="#0fb489"
          strokeWidth="5"
        />
      </svg>
      <span>Crumb</span>
      <span className="brand-divider" />
      <span className="brand-docs">Docs</span>
    </span>
  );
}
