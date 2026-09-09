import { equal } from "yuke:test";
import { NAV_KEYS } from "yuke:ui";
let threw = 0;
try { NAV_KEYS.j = () => {}; } catch (e) { if (e instanceof TypeError) threw++; }
try { NAV_KEYS.zz = () => {}; } catch (e) { if (e instanceof TypeError) threw++; }
try { delete NAV_KEYS.k; } catch (e) { if (e instanceof TypeError) threw++; }
equal(String(threw) + ":" + (typeof NAV_KEYS.j) + ":" + (typeof NAV_KEYS.k), "3:function:function");
