package com.pulsewatch.esb;

import java.io.IOException;
import java.util.List;
import java.util.UUID;

import org.apache.camel.Exchange;
import org.apache.camel.builder.RouteBuilder;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

@Component
public class NlpGatewayRoutes extends RouteBuilder {
    private static final String CORRELATION_ID = "X-Correlation-Id";
    private static final String UPSTREAM_ENDPOINT =
            "http://pulsewatch-nlp-upstream?throwExceptionOnFailure=false"
                    + "&connectTimeout=5000&responseTimeout=30000";

    @Value("${nlp.service.url}")
    private String nlpServiceUrl;

    @Override
    public void configure() {
        onException(IOException.class)
                .handled(true)
                .process(exchange -> {
                    String correlationId = exchange.getProperty(
                            "pulsewatch.correlationId", String.class);
                    exchange.getMessage().setHeader(Exchange.HTTP_RESPONSE_CODE, 502);
                    exchange.getMessage().setHeader(
                            Exchange.CONTENT_TYPE, "application/json");
                    exchange.getMessage().setHeader(CORRELATION_ID, correlationId);
                    exchange.getMessage().setBody(
                            "{\"error\":\"NLP service unavailable\"}");
                });

        from("platform-http:/health?httpMethodRestrict=GET")
                .routeId("pulsewatch-esb-health")
                .setHeader(Exchange.CONTENT_TYPE, constant("application/json"))
                .setBody(constant(
                        "{\"status\":\"ok\",\"service\":\"pulsewatch-esb\"}"));

        from("platform-http:/ready?httpMethodRestrict=GET")
                .routeId("pulsewatch-esb-readiness")
                .process(exchange -> {
                    exchange.getMessage().setHeader(Exchange.HTTP_URI, serviceBaseUrl());
                    exchange.getMessage().setHeader(Exchange.HTTP_PATH, "/health");
                    exchange.getMessage().removeHeader(Exchange.HTTP_QUERY);
                })
                .to(UPSTREAM_ENDPOINT);

        for (String servicePath : List.of(
                "/nlp", "/stocks", "/market", "/chat", "/rag", "/agents",
                "/docs", "/openapi.json")) {
            from("platform-http:" + servicePath
                    + "?matchOnUriPrefix=true&httpMethodRestrict=GET,POST")
                    .routeId("pulsewatch-" + routeName(servicePath) + "-gateway")
                    .process(exchange -> prepareUpstreamRequest(exchange, servicePath))
                    .to(UPSTREAM_ENDPOINT)
                    .process(exchange -> {
                        String correlationId = exchange.getProperty(
                                "pulsewatch.correlationId", String.class);
                        exchange.getMessage().setHeader(CORRELATION_ID, correlationId);
                    });
        }
    }

    private void prepareUpstreamRequest(Exchange exchange, String servicePath) {
        String path = exchange.getMessage().getHeader(Exchange.HTTP_URI, String.class);
        if (path == null || !path.startsWith("/")) {
            path = exchange.getMessage().getHeader(Exchange.HTTP_PATH, String.class);
        }
        if (path == null || path.isBlank()) {
            path = servicePath;
        } else if (!path.equals(servicePath)
                && !path.startsWith(servicePath + "/")) {
            path = servicePath + (path.startsWith("/") ? path : "/" + path);
        }

        String correlationId = exchange.getMessage()
                .getHeader(CORRELATION_ID, String.class);
        if (correlationId == null || correlationId.isBlank()) {
            correlationId = UUID.randomUUID().toString();
        }
        exchange.setProperty("pulsewatch.correlationId", correlationId);
        exchange.getMessage().setHeader(CORRELATION_ID, correlationId);
        exchange.getMessage().setHeader(Exchange.HTTP_URI, serviceBaseUrl());
        exchange.getMessage().setHeader(Exchange.HTTP_PATH, path);
    }

    private String serviceBaseUrl() {
        return nlpServiceUrl.replaceAll("/+$", "");
    }

    private static String routeName(String servicePath) {
        return servicePath.substring(1).replace('.', '-');
    }
}
