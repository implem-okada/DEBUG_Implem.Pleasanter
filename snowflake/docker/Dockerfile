FROM implemokada/pleasanter:latest AS base

# Bake Snowflake-specific static parameters. jq is not present in the base image
# and we don't want it in the final image, so run it in a throwaway stage.
FROM alpine:3 AS config
RUN apk add --no-cache jq
COPY --from=base /app/App_Data/Parameters/ParameterSetting.json /tmp/ParameterSetting.json
COPY --from=base /app/App_Data/Parameters/Security.json        /tmp/Security.json
RUN jq '.EnableScreenManagement = true | .EnableRestart = true' /tmp/ParameterSetting.json > /tmp/ParameterSetting.out.json \
 && jq '.PrivilegedUsers = null' /tmp/Security.json > /tmp/Security.out.json

FROM base
COPY --from=config /tmp/ParameterSetting.out.json /app/App_Data/Parameters/ParameterSetting.json
COPY --from=config /tmp/Security.out.json         /app/App_Data/Parameters/Security.json

# Copy entrypoint script
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

EXPOSE 8080

WORKDIR /app
ENTRYPOINT ["/app/entrypoint.sh"]
