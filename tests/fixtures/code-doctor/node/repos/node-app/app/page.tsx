import { formatDuration } from "../src/lib/live";

export default function Page() {
  return <main>{formatDuration(3725)}</main>;
}
