package com.pulsewatch.esb;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.server.LocalServerPort;

@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = "nlp.service.url=http://127.0.0.1:1")
class NlpGatewayUnavailableTest {
    private static final HttpClient HTTP_CLIENT = HttpClient.newHttpClient();

    @LocalServerPort
    private int port;

    @Test
    void returnsBadGatewayWhenTheNlpServiceCannotBeReached() throws Exception {
        HttpRequest request = HttpRequest.newBuilder(
                        URI.create("http://127.0.0.1:" + port + "/market/search?q=PulseWatch"))
                .GET()
                .build();
        HttpResponse<String> response = HTTP_CLIENT.send(
                request, HttpResponse.BodyHandlers.ofString());

        assertEquals(502, response.statusCode());
        assertEquals("{\"error\":\"NLP service unavailable\"}", response.body());
        assertNotNull(response.headers().firstValue("X-Correlation-Id").orElse(null));
    }
}
