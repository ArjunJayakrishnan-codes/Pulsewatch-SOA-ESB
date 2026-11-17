package com.pulsewatch.esb;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import okhttp3.mockwebserver.MockResponse;
import okhttp3.mockwebserver.MockWebServer;
import okhttp3.mockwebserver.RecordedRequest;
import org.junit.jupiter.api.AfterAll;
import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;

@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT)
class NlpGatewayRoutesTest {
    private static final MockWebServer NLP_BACKEND = startBackend();
    private static final HttpClient HTTP_CLIENT = HttpClient.newHttpClient();

    @LocalServerPort
    private int port;

    @DynamicPropertySource
    static void configureNlpBackend(DynamicPropertyRegistry registry) {
        registry.add("nlp.service.url", () -> NLP_BACKEND.url("/").toString());
    }

    @AfterAll
    static void stopBackend() throws IOException {
        NLP_BACKEND.shutdown();
    }

    @Test
    void forwardsPathQueryHeadersBodyAndUpstreamStatus() throws Exception {
        NLP_BACKEND.enqueue(new MockResponse()
                .setResponseCode(201)
                .addHeader("Content-Type", "application/json")
                .setBody("{\"accepted\":true}"));

        HttpRequest request = HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port
                                + "/nlp/chat/graph?trace=sample"))
                .header("Content-Type", "application/json")
                .header("X-Correlation-Id", "test-correlation")
                .POST(HttpRequest.BodyPublishers.ofString("{\"message\":\"test\"}"))
                .build();
        HttpResponse<String> response = HTTP_CLIENT.send(
                request, HttpResponse.BodyHandlers.ofString());

        RecordedRequest forwarded = NLP_BACKEND.takeRequest();
        assertEquals(201, response.statusCode());
        assertEquals("{\"accepted\":true}", response.body());
        assertEquals("/nlp/chat/graph?trace=sample", forwarded.getPath());
        assertEquals("POST", forwarded.getMethod());
        assertEquals("{\"message\":\"test\"}", forwarded.getBody().readUtf8());
        assertEquals("test-correlation",
                response.headers().firstValue("X-Correlation-Id").orElse(null));
    }

    @Test
    void readinessChecksTheNlpService() throws Exception {
        NLP_BACKEND.enqueue(new MockResponse()
                .setResponseCode(200)
                .addHeader("Content-Type", "application/json")
                .setBody("{\"status\":\"ok\",\"service\":\"pulsewatch-nlp\"}"));

        HttpRequest request = HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port + "/ready"))
                .GET()
                .build();
        HttpResponse<String> response = HTTP_CLIENT.send(
                request, HttpResponse.BodyHandlers.ofString());

        RecordedRequest forwarded = NLP_BACKEND.takeRequest();
        assertEquals(200, response.statusCode());
        assertEquals("/health", forwarded.getPath());
        assertNotNull(response.body());
        assertEquals("{\"status\":\"ok\",\"service\":\"pulsewatch-nlp\"}",
                response.body());
    }

    private static MockWebServer startBackend() {
        MockWebServer server = new MockWebServer();
        try {
            server.start();
            return server;
        } catch (IOException error) {
            throw new ExceptionInInitializerError(error);
        }
    }
}
