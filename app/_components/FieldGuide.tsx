import { useId, type ReactElement, cloneElement } from "react";

type ControlProps = {
  id?: string;
  "aria-describedby"?: string;
  "aria-invalid"?: boolean;
  "aria-required"?: boolean;
};

type Props = {
  label: string;
  help: string;
  required?: boolean;
  error?: string;
  example?: string;
  children: ReactElement<ControlProps>;
  className?: string;
};

/** Keep the accessible name short. Help, requirement and error are separate descriptions. */
export default function FieldGuide({ label, help, required = false, error, example, children, className = "" }: Props) {
  const generated = useId();
  const id = children.props.id ?? generated;
  const description = [id + "-help", error && id + "-error", children.props["aria-describedby"]].filter(Boolean).join(" ");
  return (
    <div className={"min-w-0 space-y-1 " + className}>
      <label htmlFor={id} className="block font-semibold">{label}</label>
      <p id={id + "-help"} className="text-sm leading-5 text-[#c2c8bb]">
        <span className="font-medium">{required ? "Wymagane" : "Opcjonalne"}</span> · {help}
        {example && <span className="block">Przykład: {example}</span>}
      </p>
      {cloneElement(children, {
        id,
        "aria-describedby": description,
        "aria-invalid": error ? true : undefined,
        "aria-required": required || undefined,
      })}
      {error && <p id={id + "-error"} className="text-sm text-[#ffc0a8]">{error}</p>}
    </div>
  );
}
