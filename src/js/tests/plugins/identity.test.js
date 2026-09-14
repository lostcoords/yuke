import { equal } from "yuke:test";
import { plugins as viaFacade } from "yuke";
import { plugins as viaExt } from "yuke:ext";
equal(viaFacade, viaExt);
