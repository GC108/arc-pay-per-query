// Worker entry. workerd treats every named export of the entry module as an entrypoint,
// so helpers live in lib.js and this module exports only the fetch handler.
import { handler } from "./lib.js";
export default handler;
