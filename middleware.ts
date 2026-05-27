import { NextResponse } from "next/server";
import type { NextRequest } from "next/server";

const ADMIN_ROUTES = [
  "/admin",
];

export function middleware(
  request: NextRequest
) {

  const path =
    request.nextUrl.pathname;

  const protectedRoute =
    ADMIN_ROUTES.some(
      route =>
      path.startsWith(route)
    );

  if(!protectedRoute){

    return NextResponse.next();

  }

  const accessToken =
    request.cookies.get(
      "sb-access-token"
    )?.value;

  if(!accessToken){

    return NextResponse.redirect(
      new URL(
        "/login",
        request.url
      )
    );

  }

  return NextResponse.next();

}

export const config = {

  matcher:[
    "/admin/:path*"
  ]

};