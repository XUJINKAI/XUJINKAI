// Copyright (c) 2020 Cesanta Software Limited
// All rights reserved

#include "mongoose.h"
#include <stdio.h>

static const char* s_web_root_dir = ".";
static const char* s_http_port = "80";
static struct mg_serve_http_opts s_http_server_opts;

static void cb(struct mg_connection* c, int ev, void* ev_data) {
	if (ev == MG_EV_HTTP_REQUEST) {
		struct http_message* message = ev_data;
		printf("request %.*s\n", message->uri.len, message->uri.p);
		mg_serve_http(c, (struct http_message*)ev_data, s_http_server_opts);
	}
}

static void usage(const char* prog) {
	fprintf(stderr,
		"Mongoose v.%s, built " __DATE__ " " __TIME__
		"\nUsage: %s OPTIONS\n"
		"  -p PORT   - bind port, default: %s\n"
		"  -d DIR    - directory to serve, default: '%s'\n",
		MG_VERSION, prog, s_http_port, s_web_root_dir);
	exit(EXIT_FAILURE);
}

int main(int argc, char* argv[]) {
	struct mg_mgr mgr;
	struct mg_connection* c;
	int i;

	// Parse command-line flags
	for (i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-d") == 0) {
			s_web_root_dir = argv[++i];
		}
		else if (strcmp(argv[i], "-p") == 0) {
			s_http_port = argv[++i];
		}
		else {
			usage(argv[0]);
		}
	}

	// Initialise stuff
	mg_mgr_init(&mgr, NULL);
	printf("Starting web server on port %s\n", s_http_port);

	c = mg_bind(&mgr, s_http_port, cb);
	if (c == NULL) {
		printf("Failed to create listener\n");
		return 1;
	}

	// Set up HTTP server parameters
	mg_set_protocol_http_websocket(c);
	s_http_server_opts.document_root = s_web_root_dir;  // Serve current directory
	s_http_server_opts.enable_directory_listing = "yes";

	// Start infinite event loop
	for (;;) {
		mg_mgr_poll(&mgr, 1000);
	}
	mg_mgr_free(&mgr);

	return 0;
}
