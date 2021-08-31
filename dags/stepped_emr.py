import os
from datetime import datetime
from datetime import timedelta

import yaml
from airflow import LoggingMixin
from airflow.configuration import conf
from airflow.contrib.operators.emr_add_steps_operator import EmrAddStepsOperator
from airflow.contrib.operators.emr_create_job_flow_operator import EmrCreateJobFlowOperator
from airflow.contrib.operators.emr_terminate_job_flow_operator import EmrTerminateJobFlowOperator
from airflow.contrib.sensors.emr_job_flow_sensor import EmrJobFlowSensor
from airflow.models import DAG, Variable, taskinstance
from airflow.operators.dummy_operator import DummyOperator
from airflow.operators.python_operator import BranchPythonOperator
from airflow.utils.db import provide_session
from airflow.utils.trigger_rule import TriggerRule

config_dir = os.path.abspath(
    os.path.join(conf.get('core', 'DAGS_FOLDER'), 'conf')) + '/'

log = LoggingMixin().logger

default_args = {
    'owner': "Rotem Fogel",
    'start_date': datetime(2021, 6, 15),
    'depends_on_past': True,
    'email': "data-infra@seekingalpha.com",
    'email_on_failure': False,
    'email_on_retry': False,
    'on_failure_callback': None,
    'retries': 3,
    'retry_delay': timedelta(seconds=5),
    'priority_weight': 10,
}


@provide_session
def clear_tasks_fn(tis, session=None, activate_dag_runs=False, dag=None) -> None:
    """
    Wrapper for `clear_task_instances` to be used in callback function
    (that accepts only `context`)
    """

    taskinstance.clear_task_instances(tis=tis,
                                      session=session,
                                      activate_dag_runs=activate_dag_runs,
                                      dag=dag)


def clear_tasks_callback(context) -> None:
    """
    Clears tasks based on list passed as `task_ids_to_clear` parameter

    To be used as `on_retry_callback`
    """

    all_tasks = context["dag_run"].get_task_instances()
    dag = context["dag"]
    task_ids_to_clear = context["params"].get("task_ids_to_clear", [])
    retries_before_clear = context["params"].get("retries_before_clear", 0)

    if context["ti"].prev_attempted_tries <= retries_before_clear:
        return

    tasks_to_clear = [ti for ti in all_tasks if ti.task_id in task_ids_to_clear]

    clear_tasks_fn(tasks_to_clear,
                   dag=dag)

    log.info(f'cleared tasks {tasks_to_clear}')


def branch(task_id: str,
           true_condition_value: str,
           false_condition_value: str,
           **context):
    if context['ti'].xcom_pull(task_ids=task_id):
        return true_condition_value
    return false_condition_value


with DAG('stepped_emr',
         catchup=False,
         schedule_interval='25 * * * *',  # in 05 hour UTC we must have NY full day cuz it is -4 / -5
         max_active_runs=1,
         default_args=default_args
         ) as dag:
    dag.doc_md = __doc__

    with open("{}{}.yaml".format(config_dir, 'stepped_emr'), 'r') as conf_file:
        emr_conf = yaml.safe_load(conf_file)
    provision = emr_conf['provision']
    step2 = emr_conf['step_2']

    s3_bucket = Variable.get('data_bucket')
    s3_bucket_override = Variable.get('data_bucket_override', s3_bucket)

    terminate_emr = EmrTerminateJobFlowOperator(task_id='terminate_emr',
                                                job_flow_id="{{ task_instance.xcom_pull('process_engine') }}",
                                                aws_conn_id='aws_default',
                                                execution_timeout=timedelta(minutes=30),
                                                )
    process_engine = EmrCreateJobFlowOperator(task_id='process_engine',
                                              job_flow_overrides=emr_conf['provision'],
                                              aws_conn_id='aws_default',
                                              pool='create_cluster',
                                              execution_timeout=timedelta(minutes=30),
                                              on_retry_callback=clear_tasks_callback,
                                              trigger_rule=TriggerRule.NONE_FAILED_OR_SKIPPED,
                                              params=dict(
                                                  input_bucket=s3_bucket_override,
                                                  output_bucket=s3_bucket,
                                                  task_ids_to_clear=['is_emr_exists', 'terminate_emr',
                                                                     'process_engine'])
                                              )

    is_emr_exists = BranchPythonOperator(task_id='is_emr_exists',
                                         python_callable=branch,
                                         op_kwargs={
                                             'task_id': process_engine.task_id,
                                             'true_condition_value': terminate_emr.task_id,
                                             'false_condition_value': process_engine.task_id
                                         },
                                         provide_context=True,
                                         execution_timeout=timedelta(minutes=2),
                                         )

    add_step = EmrAddStepsOperator(
        task_id='add_step_2',
        job_flow_id="{{ task_instance.xcom_pull('" + process_engine.task_id + "', key='return_value') }}",
        steps=step2,
        execution_timeout=timedelta(hours=5)
    )

    flow_sensor = EmrJobFlowSensor(task_id='flow_sensor',
                               job_flow_id="{{ task_instance.xcom_pull('process_engine') }}",
                               execution_timeout=timedelta(hours=1),
                               on_retry_callback=clear_tasks_callback,
                               params=dict(
                                   task_ids_to_clear=['is_emr_exists', 'terminate_emr',
                                                      'process_engine', 'flow_sensor'])
                               )

    end_of_dag = DummyOperator(task_id='end_of_dag',
                               trigger_rule=TriggerRule.NONE_FAILED_OR_SKIPPED)

    is_emr_exists >> terminate_emr >> process_engine >> add_step >> flow_sensor >> end_of_dag
    is_emr_exists >> process_engine
