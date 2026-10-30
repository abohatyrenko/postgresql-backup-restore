{{/*
Expand the name of the chart.
*/}}
{{- define "postgresql-backup-restore.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "postgresql-backup-restore.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "postgresql-backup-restore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "postgresql-backup-restore.labels" -}}
helm.sh/chart: {{ include "postgresql-backup-restore.chart" . }}
{{ include "postgresql-backup-restore.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "postgresql-backup-restore.selectorLabels" -}}
app.kubernetes.io/name: {{ include "postgresql-backup-restore.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "postgresql-backup-restore.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "postgresql-backup-restore.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Container image
*/}}
{{- define "postgresql-backup-restore.image" -}}
{{- printf "%s:%s" .Values.image.repository (.Values.image.tag | default .Chart.AppVersion) }}
{{- end }}

{{/*
Name of the Secret holding credentials, empty if there is none
*/}}
{{- define "postgresql-backup-restore.secretName" -}}
{{- if .Values.existingSecret }}
{{- .Values.existingSecret }}
{{- else if include "postgresql-backup-restore.hasSecretValues" . }}
{{- include "postgresql-backup-restore.fullname" . }}
{{- end }}
{{- end }}

{{- define "postgresql-backup-restore.hasSecretValues" -}}
{{- range $key, $value := .Values.secrets }}
{{- if $value }}true{{ end }}
{{- end }}
{{- end }}

{{/*
Fail early on values from chart versions < 1.0.0
*/}}
{{- define "postgresql-backup-restore.validateValues" -}}
{{- if and .Values.app .Values.app.cronSchedule }}
{{- fail "app.cronSchedule was renamed to backup.schedule" }}
{{- end }}
{{- if .Values.jobAnnotations }}
{{- fail "jobAnnotations was renamed to podAnnotations" }}
{{- end }}
{{- if .Values.notificationSlack }}
{{- fail "notificationSlack was replaced by secrets.slack_webhook_url and deployNotification.enabled" }}
{{- end }}
{{- end }}

{{/*
Environment variables for a job. Each job only gets the credentials it needs:
backup jobs never see the restore password / decryption key and vice versa.
Usage: include "postgresql-backup-restore.env" (dict "root" $ "env" .Values.backup.env "component" "backup")
*/}}
{{- define "postgresql-backup-restore.env" -}}
{{- $root := .root }}
{{- $secretName := include "postgresql-backup-restore.secretName" $root }}
{{- $secretEnv := dict
  "AWS_ACCESS_KEY_ID" "aws_access_key_id"
  "AWS_SECRET_ACCESS_KEY" "aws_secret_access_key"
  "SLACK_WEBHOOK_URL" "slack_webhook_url" }}
{{- $dbSecret := $root.Values.dbPasswordSecret.backup_secret }}
{{- $dbEnv := "PG_PASS_BACKUP" }}
{{- $dbKey := "postgresql_backup" }}
{{- if eq .component "restore" }}
{{- $_ := set $secretEnv "AGE_IDENTITY" "age_identity" }}
{{- $dbSecret = $root.Values.dbPasswordSecret.restore_secret }}
{{- $dbEnv = "PG_PASS_RESTORE" }}
{{- $dbKey = "postgresql_restore" }}
{{- end }}
{{- if not $dbSecret.enabled }}
{{- $_ := set $secretEnv $dbEnv $dbKey }}
{{- end }}
{{- range $name, $key := $secretEnv }}
{{- if or $root.Values.existingSecret (and $secretName (get $root.Values.secrets $key)) }}
- name: {{ $name }}
  valueFrom:
    secretKeyRef:
      name: {{ $secretName }}
      key: {{ $key }}
      optional: true
{{- end }}
{{- end }}
{{- if $dbSecret.enabled }}
- name: {{ $dbEnv }}
  valueFrom:
    secretKeyRef:
      name: {{ required (printf "dbPasswordSecret.%s_secret.name is required" .component) $dbSecret.name }}
      key: {{ $dbSecret.key | default $dbKey }}
{{- end }}
{{- range $name, $value := merge (dict) (.env | default dict) $root.Values.env }}
- name: {{ $name }}
  value: {{ $value | toString | quote }}
{{- end }}
{{- with $root.Values.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Job template shared by the backup and restore CronJobs.
Usage: include "postgresql-backup-restore.jobTemplate" (dict "root" $ "job" .Values.backup "component" "backup")
*/}}
{{- define "postgresql-backup-restore.jobTemplate" -}}
{{- $root := .root }}
{{- $job := .job }}
metadata:
  labels:
    {{- include "postgresql-backup-restore.labels" $root | nindent 4 }}
    app.kubernetes.io/component: {{ .component }}
spec:
  backoffLimit: {{ $job.backoffLimit }}
  {{- with $job.activeDeadlineSeconds }}
  activeDeadlineSeconds: {{ . }}
  {{- end }}
  {{- with $job.ttlSecondsAfterFinished }}
  ttlSecondsAfterFinished: {{ . }}
  {{- end }}
  template:
    metadata:
      labels:
        {{- include "postgresql-backup-restore.selectorLabels" $root | nindent 8 }}
        app.kubernetes.io/component: {{ .component }}
        {{- with $root.Values.podLabels }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $root.Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      restartPolicy: Never
      # Service links would inject variables like POSTGRESQL_BACKUP_PORT=tcp://... for a Service named "postgresql-backup"
      enableServiceLinks: false
      serviceAccountName: {{ include "postgresql-backup-restore.serviceAccountName" $root }}
      automountServiceAccountToken: {{ $root.Values.serviceAccount.automountServiceAccountToken }}
      {{- with $root.Values.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.priorityClassName }}
      priorityClassName: {{ . }}
      {{- end }}
      {{- with $root.Values.podSecurityContext }}
      securityContext:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      containers:
        - name: {{ .component }}
          image: {{ include "postgresql-backup-restore.image" $root | quote }}
          imagePullPolicy: {{ $root.Values.image.pullPolicy }}
          args:
            {{- toYaml $job.args | nindent 12 }}
          env:
            - name: WORK_DIR
              value: /work
            {{- include "postgresql-backup-restore.env" (dict "root" $root "env" $job.env "component" .component) | trim | nindent 12 }}
          {{- with $root.Values.envFrom }}
          envFrom:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $root.Values.securityContext }}
          securityContext:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with $root.Values.resources }}
          resources:
            {{- toYaml . | nindent 12 }}
          {{- end }}
          volumeMounts:
            - name: work
              mountPath: /work
            - name: tmp
              mountPath: /tmp
            {{- with $root.Values.extraVolumeMounts }}
            {{- toYaml . | nindent 12 }}
            {{- end }}
      volumes:
        - name: work
          {{- if $root.Values.workDir.volume }}
          {{- toYaml $root.Values.workDir.volume | nindent 10 }}
          {{- else }}
          emptyDir:
            sizeLimit: {{ $root.Values.workDir.sizeLimit }}
          {{- end }}
        - name: tmp
          emptyDir:
            sizeLimit: 256Mi
        {{- with $root.Values.extraVolumes }}
        {{- toYaml . | nindent 8 }}
        {{- end }}
      {{- with $root.Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with $root.Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
{{- end }}
