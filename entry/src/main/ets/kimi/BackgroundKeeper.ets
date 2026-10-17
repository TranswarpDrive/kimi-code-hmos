import { common, wantAgent, WantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Log } from './Log';

/**
 * 2in1 的 TASK_KEEPING 长时任务：窗口最小化/切到后台时，避免应用（连同 kimi 服务子进程）被冻结，
 * 保证长时间运行的 Agent 任务不中断。设备不支持时只记日志。
 */
export class BackgroundKeeper {
  private running: boolean = false;

  async start(context: common.UIAbilityContext): Promise<void> {
    if (this.running) {
      return;
    }
    try {
      const info: wantAgent.WantAgentInfo = {
        wants: [{ bundleName: context.abilityInfo.bundleName, abilityName: context.abilityInfo.name }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      const agent: WantAgent = await wantAgent.getWantAgent(info);
      await backgroundTaskManager.startBackgroundRunning(context,
        backgroundTaskManager.BackgroundMode.TASK_KEEPING, agent);
      this.running = true;
      Log.info('continuous task (TASK_KEEPING) started');
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`startBackgroundRunning failed (${e.code}): ${e.message}`);
    }
  }

  async stop(context: common.UIAbilityContext): Promise<void> {
    if (!this.running) {
      return;
    }
    this.running = false;
    try {
      await backgroundTaskManager.stopBackgroundRunning(context);
    } catch (err) {
      const e = err as BusinessError;
      Log.warn(`stopBackgroundRunning failed (${e.code}): ${e.message}`);
    }
  }
}
