import { NextResponse } from "next/server";

// Bad: no config.matcher, so this runs on every request, including assets.
export function middleware() {
  return NextResponse.next();
}
