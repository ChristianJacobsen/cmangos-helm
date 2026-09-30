{{- define "cmangos.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cmangos.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "cmangos.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cmangos.labels" -}}
helm.sh/chart: {{ include "cmangos.chart" . }}
app.kubernetes.io/name: {{ include "cmangos.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: cmangos
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.podLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{- define "cmangos.selectorLabels" -}}
app.kubernetes.io/name: {{ include "cmangos.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end -}}

{{- define "cmangos.podMetadata" -}}
labels:
  {{- include "cmangos.selectorLabels" . | nindent 2 }}
  {{- with .ctx.Values.podLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .ctx.Values.podAnnotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "cmangos.renderImage" -}}
{{- $registry := .registry | default "docker.io" -}}
{{- $tag := .tag | default "latest" -}}
{{- if .digest -}}
{{- printf "%s/%s:%s@%s" $registry .repository (toString $tag) .digest -}}
{{- else -}}
{{- printf "%s/%s:%s" $registry .repository (toString $tag) -}}
{{- end -}}
{{- end -}}

{{- define "cmangos.image" -}}
{{- $img := index .ctx.Values.images .component -}}
{{- if or (not $img.repository) (not $img.tag) -}}
{{- fail (printf "images.%s.repository and images.%s.tag are required. Use a published tag of ghcr.io/christianjacobsen/cmangos-classic-%s, or build your own images with `make images` and install with `-f build/images.generated.yaml`." .component .component .component) -}}
{{- end -}}
{{- include "cmangos.renderImage" $img -}}
{{- end -}}

{{- define "cmangos.pullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{- define "cmangos.db.host" -}}
{{- if .Values.mysql.enabled -}}
{{- printf "%s-mysql" (include "cmangos.fullname" .) -}}
{{- else -}}
{{- required "externalDatabase.host is required when mysql.enabled=false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{- define "cmangos.db.port" -}}
{{- if .Values.mysql.enabled -}}3306{{- else -}}{{- .Values.externalDatabase.port | int -}}{{- end -}}
{{- end -}}

{{- define "cmangos.db.secretName" -}}
{{- .Values.database.existingSecret | default (printf "%s-db" (include "cmangos.fullname" .)) -}}
{{- end -}}

{{- define "cmangos.db.adminUser" -}}
{{- if .Values.mysql.enabled -}}root{{- else -}}{{- .Values.externalDatabase.adminUser -}}{{- end -}}
{{- end -}}

{{- define "cmangos.db.adminPasswordKey" -}}
{{- if .Values.mysql.enabled -}}root-password{{- else -}}admin-password{{- end -}}
{{- end -}}

{{/* $(DB_PASSWORD) expands only when DB_PASSWORD comes earlier in the env list. */}}
{{- define "cmangos.db.info" -}}
{{- printf "%s;%s;%s;$(DB_PASSWORD);%s" (include "cmangos.db.host" .ctx) (include "cmangos.db.port" .ctx) .ctx.Values.database.user .name -}}
{{- end -}}

{{- define "cmangos.db.passwordEnv" -}}
- name: DB_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "cmangos.db.secretName" . }}
      key: password
{{- end -}}

{{/*
GetIntDefault in the core cannot parse "true", so booleans become 1 and 0.
Helm reads YAML numbers as float64, so whole numbers need a cast: 1000000
would render as 1e+06.
*/}}
{{- define "cmangos.confValue" -}}
{{- if kindIs "bool" . -}}
{{- ternary "1" "0" . -}}
{{- else if and (kindIs "float64" .) (eq (float64 (int64 .)) .) -}}
{{- int64 . -}}
{{- else -}}
{{- toString . -}}
{{- end -}}
{{- end -}}

{{/* Config::SetSource in the core reads <prefix><key>, with the dots in the key as underscores. */}}
{{- define "cmangos.confEnv" -}}
{{- $prefix := .prefix -}}
{{- range $k, $v := .config }}
- name: {{ printf "%s%s" $prefix (replace "." "_" $k) }}
  value: {{ include "cmangos.confValue" $v | quote }}
{{- end }}
{{- end -}}

{{- define "cmangos.serviceAccountName" -}}
{{- printf "%s-wait" (include "cmangos.fullname" .) -}}
{{- end -}}

{{- define "cmangos.dataClaimName" -}}
{{- .Values.clientData.existingClaim | default (printf "%s-client-data" (include "cmangos.fullname" .)) -}}
{{- end -}}

{{- define "cmangos.createDataClaim" -}}
{{- if and (not .Values.clientData.volume) (not .Values.clientData.existingClaim) -}}true{{- end -}}
{{- end -}}

{{- define "cmangos.dataVolume" -}}
{{- if .Values.clientData.volume -}}
{{- toYaml .Values.clientData.volume -}}
{{- else -}}
persistentVolumeClaim:
  claimName: {{ include "cmangos.dataClaimName" . }}
{{- end -}}
{{- end -}}

{{/* Jobs are immutable, so each release revision needs new Job names. */}}
{{- define "cmangos.dbInitJobName" -}}
{{- printf "%s-db-init-r%d" (include "cmangos.fullname" .) (.Release.Revision | int) -}}
{{- end -}}

{{- define "cmangos.clientDataJobName" -}}
{{- printf "%s-client-data-r%d" (include "cmangos.fullname" .) (.Release.Revision | int) -}}
{{- end -}}

{{- define "cmangos.realmPort" -}}
{{- $svc := .Values.mangosd.service -}}
{{- if not (kindIs "invalid" .Values.dbInit.realm.port) -}}
{{- .Values.dbInit.realm.port | int -}}
{{- else if and (eq $svc.type "NodePort") $svc.nodePort -}}
{{- $svc.nodePort | int -}}
{{- else -}}
{{- $svc.port | int -}}
{{- end -}}
{{- end -}}

{{- define "cmangos.waitDbInit" -}}
{{- if .Values.dbInit.enabled }}
- name: wait-db-init
  image: {{ include "cmangos.renderImage" .Values.images.kubectl }}
  imagePullPolicy: {{ .Values.imagePullPolicy }}
  command: ["kubectl"]
  args:
    - wait
    - --for=condition=complete
    - job/{{ include "cmangos.dbInitJobName" . }}
    - --timeout=3600s
  env:
    - name: HOME
      value: /tmp
  volumeMounts:
    - name: tmp
      mountPath: /tmp
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  resources:
    requests:
      cpu: 10m
      memory: 32Mi
    limits:
      memory: 128Mi
{{- end }}
{{- end -}}
